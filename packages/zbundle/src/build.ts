//! ORCHESTRATION: a resolved config in, files on disk out.
//!
//! Everything here is per-BUILD work — expanding inputs, naming outputs,
//! creating directories, emptying one. Not a single line looks inside a module:
//! that is the addon's job, and this file calls it once per entry.

import { existsSync, mkdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve, sep } from "node:path";
import process from "node:process";

import { bundleWith } from "../index.js";
import { ConfigError, type ResolvedConfig } from "./validate.js";

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

  if (cfg.clean) {
    assertSafeToClean(cfg.outDir);
    // `force` so a first build, with no dist/ yet, is not an error.
    rmSync(cfg.outDir, { recursive: true, force: true });
  }

  const results: BuildResult[] = [];
  for (const entry of cfg.entries) {
    const report = bundleWith(entry.file, {
      format: "esm",
      dead: false,
      minify: cfg.minify,
      resolve: { alias: cfg.alias, extensions: cfg.extensions },
    }) as { code: string; stats: Stats; dead: Dead[] };

    // `[name]` may carry a path (`'cli/index'` -> dist/cli/index.js): the
    // subdirectories come from the key, exactly as with rolldown.
    const outFile = join(cfg.outDir, cfg.entryFileNames.replace(/\[name\]/g, entry.name));
    mkdirSync(dirname(outFile), { recursive: true });
    writeFileSync(outFile, report.code);

    results.push({
      name: entry.name,
      entry: entry.file,
      outFile,
      stats: report.stats,
      dead: report.dead ?? [],
    });
  }
  return results;
}

/** Total bytes written, for the recap line. */
export function totalBytes(results: BuildResult[]): number {
  return results.reduce((n, r) => n + (existsSync(r.outFile) ? statSync(r.outFile).size : 0), 0);
}
