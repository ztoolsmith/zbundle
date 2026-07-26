#!/usr/bin/env node
//! The `zbundle` command: bundling from a terminal, without writing glue.
//!
//! All the work lives in the addon (`../index.js`). This file does three things,
//! and that is deliberate:
//!   1. read arguments,
//!   2. write the result somewhere,
//!   3. **present refusals** — the part that really matters. A bundler that
//!      refuses must say what to do, and say it readably.
import { parseArgs } from "node:util";
import { writeFileSync, watch, existsSync, statSync } from "node:fs";
import { dirname, resolve, relative } from "node:path";
import process from "node:process";

import { bundleWith, graphPrint, VERSION } from "../index.js";

const HELP = `zbundle — a JavaScript/TypeScript bundler written in Zig

Usage:
  zbundle <entry> [-o <file>]         Bundle (ESM, a single file)
  zbundle <entry> --graph             Show the module graph, without bundling
  zbundle <entry> --dead              Bundle + list what tree-shaking removed
  zbundle <entry> --watch -o <f>      Rebundle on every change

Options:
  -o, --out <file>      Write here (default: standard output)
  -f, --format <fmt>    esm (default) | iife  — iife needs zero external deps
      --dead            List removed code (module, line, reason)
      --graph           The module graph instead of the bundle
      --watch           Rebuild when a module changes (requires -o)
      --quiet           No statistics
  -h, --help            This help
  -v, --version         The version

Statistics go to STDERR: \`zbundle src/index.js > out.js\` gives a clean file,
and the numbers stay readable on screen.
`;

// Colours only when talking to a terminal (otherwise we pollute pipes).
const tty = process.stderr.isTTY === true;
const c = (code: string, s: string) => (tty ? `\x1b[${code}m${s}\x1b[0m` : s);
const bold = (s: string) => c("1", s);
const dim = (s: string) => c("2", s);
const red = (s: string) => c("31", s);
const green = (s: string) => c("32", s);

interface Stats {
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

function fail(message: string): never {
  process.stderr.write(`${red("✘")} ${message.replace(/\n/g, "\n  ")}\n`);
  process.exit(1);
}

/** The numbers, on one dense but readable line. */
function reportStats(s: Stats, out: string | undefined, format: string): void {
  const pct = s.input_bytes > 0 ? ((100 * s.output_bytes) / s.input_bytes).toFixed(0) : "0";
  // The shorter of the two: a relative path full of `../..` is unreadable.
  const rel = out ? relative(process.cwd(), out) : "";
  const where = out ? (rel.length < out.length ? rel : out) : "(stdout)";
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

interface Dead {
  module: string;
  line: number;
  snippet: string;
  reason: string;
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

/**
 * One build. Returns the module paths, for --watch.
 *
 * **Does not exit the process**: the caller decides. In one-shot mode an error
 * is fatal; under `--watch` it must not be — we print, keep control, and the
 * next save retries.
 */
function build(entry: string, opts: { out?: string; format: string; dead: boolean; quiet: boolean }): string[] {
  const result = bundleWith(entry, { format: opts.format, dead: opts.dead }) as {
    code: string;
    stats: Stats;
    dead: Dead[];
  };

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

function main(): void {
  const { values, positionals } = parseArgs({
    args: process.argv.slice(2),
    allowPositionals: true,
    options: {
      out: { type: "string", short: "o" },
      format: { type: "string", short: "f", default: "esm" },
      dead: { type: "boolean", default: false },
      graph: { type: "boolean", default: false },
      watch: { type: "boolean", default: false },
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
  if (positionals.length === 0) {
    process.stderr.write(HELP);
    process.exit(1);
  }
  if (positionals.length > 1) {
    fail(`only one entry at a time (received: ${positionals.join(", ")})`);
  }

  const entry = resolve(positionals[0]!);
  if (!existsSync(entry)) fail(`entry not found: ${positionals[0]}`);

  if (values.graph) {
    process.stdout.write(graphPrint(entry));
    return;
  }

  const out = values.out ? resolve(values.out) : undefined;
  const opts = { out, format: values.format!, dead: values.dead!, quiet: values.quiet! };

  if (!values.watch) {
    try {
      build(entry, opts);
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
      return build(entry, opts);
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

try {
  main();
} catch (err) {
  fail(err instanceof Error ? err.message : String(err));
}
