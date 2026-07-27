#!/usr/bin/env node
//! The `zbundle` command: bundling from a terminal, without writing glue.
//!
//! All the work lives in the addon (`../index.js`). This file does four things,
//! and that is deliberate:
//!   1. read arguments,
//!   2. resolve the configuration (CLI > config file > defaults),
//!   3. write the result somewhere,
//!   4. **present refusals** — the part that really matters. A bundler that
//!      refuses must say what to do, and say it readably.
//!
//! Two shapes coexist, on purpose:
//!   - `zbundle build` — the project form: reads `zbundle.config.ts`, may emit
//!     several bundles, writes into a directory.
//!   - `zbundle <entry>` — the one-shot form: no config, one bundle, stdout by
//!     default. It is what makes the tool usable in a pipe, and it predates the
//!     config layer; it stays exactly as it was.
import { parseArgs } from "node:util";
import { writeFileSync, watch, existsSync, statSync } from "node:fs";
import { dirname, resolve, relative } from "node:path";
import process from "node:process";

import { bundleWith, graphPrint, VERSION } from "../index.js";
import { DEFAULT_EXTENSIONS } from "./config.js";
import { findConfigFile, loadConfigModule, ConfigError, CONFIG_NAMES } from "./load.js";
import { validate, type ResolvedConfig } from "./validate.js";
import { runBuild, type BuildResult, type Dead, type Stats } from "./build.js";

const HELP = `zbundle — a JavaScript/TypeScript bundler written in Zig

Usage:
  zbundle build                       Build from zbundle.config.ts
  zbundle build <entry>               Build one entry, ignoring any config
  zbundle <entry> [-o <file>]         One-shot: bundle to stdout (or -o)
  zbundle <entry> --graph             Show the module graph, without bundling
  zbundle <entry> --dead              Bundle + list what tree-shaking removed
  zbundle <entry> --watch -o <f>      Rebundle on every change

Build options:
  -c, --config <file>   Config file (default: zbundle.config.{ts,mts,js,mjs,cjs})
      --out-dir <dir>   Override output.dir
      --dead            List removed code, per bundle

Shared:
      --minify          Override minify (default: mode === "production")

One-shot options:
  -o, --out <file>      Write here (default: standard output)
  -f, --format <fmt>    esm (default) | iife  — iife needs zero external deps
      --dead            List removed code (module, line, reason)
      --graph           The module graph instead of the bundle
      --watch           Rebuild when a module changes (requires -o)

  --quiet               No statistics
  -h, --help            This help
  -v, --version         The version

The two families do not mix: a build option on the one-shot form (or the other
way round) is an ERROR naming where it belongs, never a silent no-op.
Command-line options WIN over the config file, which wins over the defaults.
Statistics go to STDERR: \`zbundle src/index.js > out.js\` gives a clean file,
and the numbers stay readable on screen.
`;

// Colours only when talking to a terminal (otherwise we pollute pipes).
const tty = process.stderr.isTTY === true;
const c = (code: string, s: string) => (tty ? `\x1b[${code}m${s}\x1b[0m` : s);
const bold = (s: string) => c("1", s);
const dim = (s: string) => c("2", s);
const red = (s: string) => c("31", s);
const yellow = (s: string) => c("33", s);
const green = (s: string) => c("32", s);

function fail(message: string): never {
  process.stderr.write(`${red("✘")} ${message.replace(/\n/g, "\n  ")}\n`);
  process.exit(1);
}

/** The shorter of absolute and cwd-relative: a path full of `../..` helps no one. */
function short(p: string): string {
  const rel = relative(process.cwd(), p);
  return rel.length < p.length ? rel : p;
}

function human(bytes: number): string {
  return bytes < 1024 ? `${bytes} B` : `${(bytes / 1024).toFixed(1)} KB`;
}

/** The numbers, on one dense but readable line. */
function reportStats(s: Stats, out: string | undefined, format: string): void {
  const pct = s.input_bytes > 0 ? ((100 * s.output_bytes) / s.input_bytes).toFixed(0) : "0";
  const where = out ? short(out) : "(stdout)";
  const shaken =
    s.statements_dropped > 0
      ? dim(`  −${s.statements_dropped} statements, −${s.modules_dropped} modules`)
      : "";
  process.stderr.write(
    `${green("✔")} ${bold(where)}  ${s.modules} modules  ${s.externals} externals${shaken}\n` +
      `  ${s.input_bytes} → ${s.output_bytes} octets (${pct} %) en ${s.bundle_ms.toFixed(2)} ms  ${dim(format)}\n`,
  );
  // An IIFE exports nothing: if the entry did export, we SAY so.
  if (format === "iife" && s.entry_exports > 0) {
    process.stderr.write(
      dim(`  note: ${s.entry_exports} entry export(s) lost — an IIFE exports nothing\n`),
    );
  }
}

/** What tree-shaking removed, grouped by module. */
function reportDead(dead: Dead[]): void {
  if (dead.length === 0) {
    process.stderr.write(dim("  (nothing removed: everything was reachable)\n"));
    return;
  }
  const byModule = new Map<string, Dead[]>();
  for (const d of dead) {
    const list = byModule.get(d.module) ?? [];
    list.push(d);
    byModule.set(d.module, list);
  }
  process.stderr.write(`\n${bold("removed by tree-shaking")}\n`);
  for (const [mod, list] of byModule) {
    process.stderr.write(`  ${mod}\n`);
    for (const d of list) {
      process.stderr.write(`    ${dim(`L${d.line}`)} ${d.snippet}\n`);
      process.stderr.write(`       ${dim(`↳ ${d.reason}`)}\n`);
    }
  }
}

// ─────────────────────────────── zbundle build ───────────────────────────────

interface Overrides {
  outDir?: string;
  minify?: boolean;
}

/**
 * The config for a `build` run, defaults included.
 *
 * **The hierarchy, in one place: CLI > config file > defaults.** The config is
 * resolved first (it knows its own directory, which is what relative paths in it
 * are relative to), then the command line overwrites what it was given
 * explicitly. An override coming from the CLI is resolved against the CWD —
 * that is where the user typed it.
 */
async function resolveForBuild(
  entryArg: string | undefined,
  configArg: string | undefined,
  over: Overrides,
): Promise<{ config: ResolvedConfig; warnings: string[]; configFile: string | null }> {
  const cwd = process.cwd();

  // `zbundle build <entry>` deliberately BYPASSES the config: it is the "just
  // build this one file with the defaults" escape hatch. Combining it with
  // --config would make the precedence ambiguous, so we refuse instead.
  if (entryArg !== undefined) {
    if (configArg !== undefined) {
      throw new ConfigError(
        `build <entry> ignores the config file, so --config cannot be combined with it.\n` +
          `  Either drop the entry (\`zbundle build --config ${configArg}\`) or drop --config.`,
      );
    }
    const { config, warnings } = validate({ input: entryArg }, cwd);
    return { config: applyOverrides(config, over, cwd), warnings, configFile: null };
  }

  const file = findConfigFile(cwd, configArg);
  if (file === null) {
    throw new ConfigError(
      `no config file found in ${cwd}\n` +
        `  looked for: ${CONFIG_NAMES.join(", ")}\n` +
        `  or build a single entry directly: zbundle build src/index.ts`,
    );
  }
  const raw = await loadConfigModule(file);
  const { config, warnings } = validate(raw, dirname(file));
  return { config: applyOverrides(config, over, cwd), warnings, configFile: file };
}

function applyOverrides(config: ResolvedConfig, over: Overrides, cwd: string): ResolvedConfig {
  return {
    ...config,
    outDir: over.outDir !== undefined ? resolve(cwd, over.outDir) : config.outDir,
    minify: over.minify !== undefined ? over.minify : config.minify,
  };
}

/** One aligned line per bundle, then the totals. */
function reportBuild(results: BuildResult[], cfg: ResolvedConfig, quiet: boolean): void {
  if (quiet) return;
  const width = Math.max(...results.map((r) => short(r.outFile).length));
  let ms = 0;
  let bytes = 0;
  for (const r of results) {
    ms += r.stats.bundle_ms;
    bytes += r.stats.output_bytes;
    const shaken =
      r.stats.statements_dropped > 0 ? dim(`  −${r.stats.statements_dropped} statements`) : "";
    process.stderr.write(
      `${green("✔")} ${bold(short(r.outFile).padEnd(width))}  ` +
        `${String(r.stats.modules).padStart(3)} modules  ` +
        `${human(r.stats.output_bytes).padStart(8)}  ` +
        `${r.stats.bundle_ms.toFixed(2)} ms${shaken}\n`,
    );
  }
  const what = results.length === 1 ? "bundle" : "bundles";
  const mode = cfg.minify ? "minified" : "readable";
  process.stderr.write(
    dim(`  ${results.length} ${what}, ${human(bytes)} total in ${ms.toFixed(2)} ms  (${mode})\n`),
  );
}

/**
 * An option belonging to the OTHER form is an error, never a no-op.
 *
 * `zbundle build -o out.js` used to exit 0 having ignored `-o` entirely — the
 * exact behaviour this project refuses for config options ("an option that is
 * accepted must act"). The CLI does not get an exemption from its own rule.
 */
function rejectForeignFlags(
  values: Record<string, unknown>,
  offenders: { flag: string; key: string; why: string }[],
): void {
  for (const { flag, key, why } of offenders) {
    const given = values[key];
    if (given === undefined || given === false) continue;
    fail(`${flag} does not apply here.\n  ${why}`);
  }
}

async function runBuildCommand(
  entryArg: string | undefined,
  values: Record<string, unknown>,
): Promise<void> {
  rejectForeignFlags(values, [
    {
      flag: "-o/--out",
      key: "out",
      why: "`build` writes into output.dir, named by output.entryFileNames.\n" +
        "  For a single file on a path you choose: zbundle <entry> -o <file>",
    },
    {
      flag: "-f/--format",
      key: "format",
      why: "a config emits esm only (output.format).\n" +
        "  For an IIFE: zbundle <entry> -f iife",
    },
    {
      flag: "--graph",
      key: "graph",
      why: "the graph is a one-shot probe: zbundle <entry> --graph",
    },
    {
      flag: "--watch",
      key: "watch",
      why: "reserved — planned for v0.4. Follow https://github.com/ztoolsmith/zbundle/issues\n" +
        "  The one-shot form has an interim watch: zbundle <entry> --watch -o <file>",
    },
  ]);

  const { config, warnings, configFile } = await resolveForBuild(
    entryArg,
    values.config as string | undefined,
    {
      outDir: values["out-dir"] as string | undefined,
      minify: values.minify as boolean | undefined,
    },
  );

  // Warnings first: they are about the config we are ABOUT to use.
  for (const w of warnings) process.stderr.write(`${yellow("⚠")} ${w}\n`);
  if (!values.quiet && configFile) process.stderr.write(dim(`— ${short(configFile)}\n`));

  const results = runBuild(config, values.dead === true);
  reportBuild(results, config, values.quiet === true);
  if (values.dead === true) {
    for (const r of results) {
      process.stderr.write(`\n${bold(short(r.outFile))}`);
      reportDead(r.dead);
    }
  }
}

// ────────────────────────────── zbundle <entry> ──────────────────────────────

/**
 * One one-shot build. Returns the module paths, for --watch.
 *
 * **Does not exit the process**: the caller decides. In one-shot mode an error
 * is fatal; under `--watch` it must not be — we print, keep control, and the
 * next save retries.
 */
function buildOnce(
  entry: string,
  opts: { out?: string; format: string; dead: boolean; quiet: boolean; minify: boolean },
): string[] {
  const result = bundleWith(entry, {
    format: opts.format,
    dead: opts.dead,
    minify: opts.minify,
    resolve: { alias: [], extensions: [...DEFAULT_EXTENSIONS] },
  }) as { code: string; stats: Stats; dead: Dead[] };

  if (opts.out) writeFileSync(opts.out, result.code);
  else process.stdout.write(result.code);

  if (!opts.quiet) reportStats(result.stats, opts.out, opts.format);
  if (opts.dead) reportDead(result.dead);

  // The modules actually read, so we know what to watch.
  return modulesOf(entry);
}

/** The graph's module paths (for --watch). */
function modulesOf(entry: string): string[] {
  try {
    // `graphPrint` is already there; no need for extra API for so little. The
    // printed paths are relative to the entry's directory.
    const root = dirname(entry);
    return graphPrint(entry)
      .split("\n")
      .map((l) => l.trim().replace(/\s+\(.*\)$/, ""))
      .filter((l) => l.startsWith("./"))
      .map((l) => resolve(root, l))
      .filter((p) => existsSync(p) && statSync(p).isFile());
  } catch {
    return [entry];
  }
}

function runOneShot(positional: string, values: Record<string, unknown>): void {
  rejectForeignFlags(values, [
    { flag: "-c/--config", key: "config", why: "a config file is read by: zbundle build --config <file>" },
    { flag: "--out-dir", key: "out-dir", why: "the one-shot form writes one file: use -o <file>, or zbundle build" },
  ]);

  const entry = resolve(positional);
  if (!existsSync(entry)) fail(`entry not found: ${positional}`);

  if (values.graph) {
    process.stdout.write(graphPrint(entry));
    return;
  }

  const out = values.out ? resolve(values.out as string) : undefined;
  const opts = {
    out,
    format: (values.format as string | undefined) ?? "esm",
    dead: values.dead === true,
    quiet: values.quiet === true,
    minify: values.minify === true,
  };

  if (!values.watch) {
    try {
      buildOnce(entry, opts);
    } catch (err) {
      // THE moment that matters: zbundle's refusals say what to do. We re-emit
      // them as is, without reformatting.
      fail(err instanceof Error ? err.message : String(err));
    }
    return;
  }

  // --watch: without -o we would write the bundle to the terminal on every keystroke.
  if (!out) fail("--watch requires -o <file> (otherwise the bundle goes to the terminal)");

  /** A watch build: never fatal, we keep control whatever happens. */
  const attempt = (): string[] => {
    try {
      return buildOnce(entry, opts);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      process.stderr.write(`${red("✘")} ${message.replace(/\n/g, "\n  ")}\n`);
      return watched; // keep watching the same files
    }
  };

  let watched = modulesOf(entry);
  watched = attempt();
  let timer: NodeJS.Timeout | undefined;
  const rebuild = () => {
    clearTimeout(timer);
    // An editor often writes in several steps: let it settle.
    timer = setTimeout(() => {
      process.stderr.write(dim(`\n— rebuild ${new Date().toLocaleTimeString()}\n`));
      watched = attempt();
      rearm();
    }, 30);
  };

  let watchers: ReturnType<typeof watch>[] = [];
  const rearm = () => {
    for (const w of watchers) w.close();
    watchers = watched.map((p) => watch(p, rebuild));
  };
  rearm();
  process.stderr.write(dim(`— watch: ${watched.length} modules watched (Ctrl-C to stop)\n`));
}

// ──────────────────────────────────── main ───────────────────────────────────

async function main(): Promise<void> {
  const { values, positionals } = parseArgs({
    args: process.argv.slice(2),
    allowPositionals: true,
    options: {
      // build
      config: { type: "string", short: "c" },
      "out-dir": { type: "string" },
      // `minify` gets NO default: absent must stay distinguishable from
      // `--minify false`, otherwise the CLI would always override the config.
      minify: { type: "boolean" },
      // one-shot
      out: { type: "string", short: "o" },
      format: { type: "string", short: "f" },
      dead: { type: "boolean", default: false },
      graph: { type: "boolean", default: false },
      watch: { type: "boolean", default: false },
      // both
      quiet: { type: "boolean", default: false },
      help: { type: "boolean", short: "h", default: false },
      version: { type: "boolean", short: "v", default: false },
    },
  });

  if (values.help) {
    process.stdout.write(HELP);
    return;
  }
  if (values.version) {
    process.stdout.write(`${VERSION}\n`);
    return;
  }

  if (positionals[0] === "build") {
    if (positionals.length > 2) {
      fail(`build takes at most one entry (received: ${positionals.slice(1).join(", ")})`);
    }
    await runBuildCommand(positionals[1], values as Record<string, unknown>);
    return;
  }

  if (positionals.length === 0) {
    process.stderr.write(HELP);
    process.exit(1);
  }
  if (positionals.length > 1) {
    fail(`only one entry at a time (received: ${positionals.join(", ")})`);
  }
  runOneShot(positionals[0]!, values as Record<string, unknown>);
}

main().catch((err) => fail(err instanceof Error ? err.message : String(err)));
