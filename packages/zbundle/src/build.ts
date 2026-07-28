//! ORCHESTRATION: a resolved config in, files on disk out.
//!
//! Everything here is per-BUILD work — expanding inputs, naming outputs,
//! creating directories, emptying one. Not a single line looks inside a module:
//! that is the addon's job, and this file calls it once per entry.

import { existsSync, mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import process from "node:process";

import { bundleWith } from "../index.js";
import { ConfigError, type ResolvedConfig } from "./validate.js";
import { translate, type ScopedAlias, type TsconfigInfo } from "./tsconfig.js";

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

    // **Nothing escapes output.dir.** A `..` in an input KEY (`{ "../x": … }`)
    // or in `entryFileNames` used to write outside the directory the user
    // declared, silently. `output.dir` is the contract: everything the build
    // produces lives under it, and nowhere else.
    const inside = relative(cfg.outDir, outFile);
    if (inside.startsWith("..") || isAbsolute(inside)) {
      throw new ConfigError(
        `output: ${short(outFile)} is outside output.dir (${short(cfg.outDir)}).\n` +
          `  Entry "${entry.name}" escapes it — a name may create subdirectories, never leave.\n` +
          `  Set output.dir if you want to write somewhere else.`,
      );
    }

    // A bundle must never be written OVER one of its own inputs. `output.dir: ""`
    // used to resolve to the config's directory and do exactly that: the source
    // was replaced by its own bundle, and there is no undo.
    const victim = cfg.entries.find((e) => resolve(e.file) === resolve(outFile));
    if (victim) {
      throw new ConfigError(
        `output: the bundle for "${entry.name}" would be written over a source file:\n` +
          `    ${short(victim.file)}\n` +
          `  Point output.dir at a directory of its own (dist/, build/…).`,
      );
    }

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

/** Directories a tsconfig scan has no business entering. */
const SKIP_DIRS = new Set(["node_modules", "dist", "build", "out", "coverage", ".git"]);

/**
 * Every `tsconfig.json` that could govern a module of this build.
 *
 * **Why a directory scan rather than a graph pass.** The honest requirement is
 * "the nearest tsconfig of every FILE", and the file set only exists inside the
 * Zig graph. Building the graph first to learn it does not work: in the very
 * case that motivates per-file configs — a monorepo — the graph cannot be built
 * until the second package's `paths` are known, so the discovery pass would fail
 * on exactly what it was meant to discover.
 *
 * Scanning is complete instead, and cheap: it reads directory entries, never
 * module contents, and stops at `node_modules` and build outputs. Combined with
 * SCOPED aliases (each tsconfig governs its own directory, nearest scope wins in
 * `resolver.zig`), per-file resolution falls out with no extra parse.
 */
function collectTsconfigFiles(root: string, entries: { file: string }[], outDir: string): string[] {
  const found = new Set<string>();
  const roots = new Set<string>();

  // Upwards from every entry: configs ABOVE the project still govern it.
  for (const { file } of entries) {
    let dir = dirname(file);
    for (;;) {
      const candidate = join(dir, "tsconfig.json");
      if (existsSync(candidate)) found.add(resolve(candidate));
      roots.add(dir);
      const parent = dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
  }

  // Downwards from the PROJECT ROOT — the config file's directory. Starting at
  // an entry's own directory was the first attempt and it misses the case that
  // matters: in a monorepo, `pkgs/b/tsconfig.json` is a SIBLING of the entry's
  // package, neither above it nor below it.
  const outAbs = resolve(outDir);
  const walk = (dir: string, depth: number): void => {
    if (depth > 8 || resolve(dir) === outAbs) return;
    let items;
    try {
      items = readdirSync(dir, { withFileTypes: true });
    } catch {
      return; // unreadable directory: not our problem to report
    }
    for (const item of items) {
      if (!item.isDirectory()) continue;
      if (item.name.startsWith(".") || SKIP_DIRS.has(item.name)) continue;
      const sub = join(dir, item.name);
      const candidate = join(sub, "tsconfig.json");
      if (existsSync(candidate)) found.add(resolve(candidate));
      walk(sub, depth + 1);
    }
  };
  walk(root, 0);

  return [...found];
}

/** What the tsconfigs contribute, merged and ready for the addon. */
export interface TsconfigContribution {
  aliases: ScopedAlias[];
  jsxImportSource?: string;
  warnings: string[];
}

/**
 * Reads the tsconfigs and turns them into aliases.
 *
 * **The priority rule, applied here in one place: what the zbundle config says
 * WINS.** A tsconfig alias whose key is also declared in `resolve.alias` is
 * dropped — the user who wrote it in `zbundle.config.ts` knew what they were
 * doing. Same for `jsx.importSource`.
 */
export function readTsconfigs(cfg: ResolvedConfig): TsconfigContribution {
  if (cfg.tsconfig === false) return { aliases: [], warnings: [] };

  // `"auto"` is the sentinel, not a path — `typeof === "string"` is true for
  // both, and forgetting that made every build look for a file called "auto".
  const forcedFile = cfg.tsconfig !== "auto" && typeof cfg.tsconfig === "string" ? cfg.tsconfig : null;
  const files = forcedFile !== null ? [forcedFile] : collectTsconfigFiles(cfg.root, cfg.entries, cfg.outDir);
  if (files.length === 0) return { aliases: [], warnings: [] };

  const infos: TsconfigInfo[] = [];
  for (const file of files) {
    if (!existsSync(file)) {
      throw new ConfigError(`tsconfig: not found: ${short(file)}`);
    }
    infos.push(translate(file));
  }

  const warnings = infos.flatMap((i) => i.warnings);
  // An explicitly named tsconfig governs the whole build, not just its own
  // directory: naming it IS saying "use this one for everything".
  const forced = forcedFile !== null;
  const explicitKeys = new Set(cfg.alias.map((a) => a.from));
  const aliases: ScopedAlias[] = [];
  for (const info of infos) {
    for (const alias of info.aliases) {
      if (explicitKeys.has(alias.from)) continue; // resolve.alias wins
      aliases.push(forced ? { ...alias, scope: "" } : alias);
    }
  }

  // `jsxImportSource` is one value for the whole build. The nearest tsconfig to
  // the first entry decides; a disagreement is said out loud rather than picked
  // silently.
  const sources = [...new Set(infos.map((i) => i.jsxImportSource).filter((v): v is string => !!v))];
  if (sources.length > 1) {
    warnings.push(
      `tsconfig: several jsxImportSource values (${sources.map((s) => JSON.stringify(s)).join(", ")}); ` +
        `zbundle uses ${JSON.stringify(sources[0])} for the whole build`,
    );
  }
  return { aliases, jsxImportSource: sources[0], warnings };
}

/**
 * Runs the whole build: one INDEPENDENT bundle per entry.
 *
 * Independent is the honest word: two entries sharing a module get their own
 * copy of it. Factoring it out means emitting a shared chunk, which is code
 * splitting — a chantier of its own, not something to fake here.
 */
export function runBuild(
  cfg: ResolvedConfig,
  withDead = false,
  ts: TsconfigContribution = { aliases: [], warnings: [] },
): BuildResult[] {
  for (const e of cfg.entries) {
    if (!existsSync(e.file)) {
      throw new ConfigError(`input: entry not found: ${e.file}`);
    }
  }
  // Before `clean` empties anything: a config that cannot produce a coherent
  // result must fail without having deleted the previous one.
  const plan = planOutputs(cfg);

  if (existsSync(cfg.outDir) && !statSync(cfg.outDir).isDirectory()) {
    throw new ConfigError(
      `output.dir: ${short(cfg.outDir)} exists and is not a directory.\n` +
        `  Remove it, or point output.dir somewhere else.`,
    );
  }

  if (cfg.clean) {
    assertSafeToClean(cfg.outDir);
    // `force` so a first build, with no dist/ yet, is not an error.
    rmSync(cfg.outDir, { recursive: true, force: true });
  }

  const results: BuildResult[] = [];
  for (const { name, file, outFile } of plan) {
    const report = bundleWith(file, {
      format: "esm",
      dead: withDead,
      minify: cfg.minify,
      // The explicit aliases come FIRST; ties are already impossible (the
      // tsconfig ones colliding by key were dropped in `readTsconfigs`).
      resolve: { alias: [...cfg.alias, ...ts.aliases], extensions: cfg.extensions },
      jsx_import_source: cfg.jsxImportSource ?? ts.jsxImportSource ?? "react",
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
