//! ORCHESTRATION: a resolved config in, files on disk out.
//!
//! Everything here is per-BUILD work — expanding inputs, naming outputs,
//! creating directories, emptying one. Not a single line looks inside a module:
//! that is the addon's job, and this file calls it once per entry.

import { existsSync, mkdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import process from "node:process";

import { bundleWith } from "../index.js";
import { ConfigError, type ResolvedConfig } from "./validate.js";

/** The shorter of absolute and cwd-relative — an error message is read, not parsed. */
function short(p: string): string {
  const rel = relative(process.cwd(), p);
  return rel.length < p.length ? rel : p;
}

export interface Stats {
  modules: number;
  modules_dropped: number;
  externals: number;
  renamed: number;
  statements_kept: number;
  statements_dropped: number;
  entry_exports: number;
  input_bytes: number;
  output_bytes: number;
  bundle_ms: number;
}

export interface Dead {
  module: string;
  line: number;
  snippet: string;
  reason: string;
}

export interface BuildResult {
  name: string;
  entry: string;
  outFile: string;
  stats: Stats;
  dead: Dead[];
}

/**
 * Refuses to empty a directory that would take the project down with it.
 *
 * `clean` is the one option here that DELETES, so it is the one that gets a
 * guard. Emptying the cwd, or any ancestor of it, is never what someone meant
 * by `output.dir` — it is a typo (`dir: '.'`, `dir: '../..'`) and it must fail
 * loudly before anything is removed.
 */
export function assertSafeToClean(dir: string, cwd: string = process.cwd()): void {
  const target = resolve(dir);
  const here = resolve(cwd);
  const why = (reason: string): never => {
    throw new ConfigError(
      `output.clean: refusing to empty ${target} — ${reason}.\n` +
        `  Point output.dir at a directory that belongs to the build (dist/, build/…).`,
    );
  };
  if (dirname(target) === target) why("it is the filesystem root");
  if (target === here) why("it is the current directory");
  if (here.startsWith(target + sep)) why("the current directory is inside it");
}

/**
 * Where each entry will be written — computed for ALL of them before anything is
 * emitted, so a collision is caught while it is still harmless.
 *
 * **Two entries writing to the same file is refused.** Without this the second
 * one silently overwrites the first, and the recap cheerfully reports "2
 * bundles" while a single file exists on disk. It is not a contrived case: two
 * entries named `index` (`src/a/index.ts` and `src/b/index.ts`) collide by
 * default, and so does any `entryFileNames` without `[name]`.
 */
function planOutputs(cfg: ResolvedConfig): { name: string; file: string; outFile: string }[] {
  const plan: { name: string; file: string; outFile: string }[] = [];
  const seen = new Map<string, { name: string; file: string }>();
  for (const entry of cfg.entries) {
    // `[name]` may carry a path (`'cli/index'` -> dist/cli/index.js): the
    // subdirectories come from the key, exactly as with rolldown.
    const outFile = join(cfg.outDir, cfg.entryFileNames.replace(/\[name\]/g, entry.name));
    const clash = seen.get(outFile);
    if (clash) {
      const hint = cfg.entryFileNames.includes("[name]")
        ? `  Both entries are named "${entry.name}". Use the object form of \`input\` to name them apart:\n` +
          `    input: { a: ${JSON.stringify(short(clash.file))}, b: ${JSON.stringify(short(entry.file))} }`
        : `  output.entryFileNames is ${JSON.stringify(cfg.entryFileNames)} — it has no [name],\n` +
          `  so every entry lands on the same file. Add [name] to it.`;
      throw new ConfigError(
        `output: two entries would be written to the same file: ${short(outFile)}\n` +
          `    ${short(clash.file)}\n    ${short(entry.file)}\n${hint}`,
      );
    }
    seen.set(outFile, { name: entry.name, file: entry.file });
    plan.push({ name: entry.name, file: entry.file, outFile });
  }
  return plan;
}

/**
 * Runs the whole build: one INDEPENDENT bundle per entry.
 *
 * Independent is the honest word: two entries sharing a module get their own
 * copy of it. Factoring it out means emitting a shared chunk, which is code
 * splitting — a chantier of its own, not something to fake here.
 */
export function runBuild(cfg: ResolvedConfig): BuildResult[] {
  for (const e of cfg.entries) {
    if (!existsSync(e.file)) {
      throw new ConfigError(`input: entry not found: ${e.file}`);
    }
  }
  // Before `clean` empties anything: a config that cannot produce a coherent
  // result must fail without having deleted the previous one.
  const plan = planOutputs(cfg);

  if (cfg.clean) {
    assertSafeToClean(cfg.outDir);
    // `force` so a first build, with no dist/ yet, is not an error.
    rmSync(cfg.outDir, { recursive: true, force: true });
  }

  const results: BuildResult[] = [];
  for (const { name, file, outFile } of plan) {
    const report = bundleWith(file, {
      format: "esm",
      dead: false,
      minify: cfg.minify,
      resolve: { alias: cfg.alias, extensions: cfg.extensions },
    }) as { code: string; stats: Stats; dead: Dead[] };

    mkdirSync(dirname(outFile), { recursive: true });
    writeFileSync(outFile, report.code);

    results.push({ name, entry: file, outFile, stats: report.stats, dead: report.dead ?? [] });
  }
  return results;
}

/** Total bytes written, for the recap line. */
export function totalBytes(results: BuildResult[]): number {
  return results.reduce((n, r) => n + (existsSync(r.outFile) ? statSync(r.outFile).size : 0), 0);
}
