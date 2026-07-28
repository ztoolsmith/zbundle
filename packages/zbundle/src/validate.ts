//! VALIDATION, by hand. No zod, no schema library: zbundle ships zero runtime
//! dependencies, and a config this small does not justify breaking that.
//!
//! Two different reactions, and the difference is the whole design:
//!   - an **unknown key** is a WARNING plus a suggestion. Your build still runs;
//!     you probably made a typo, and we say which key you likely meant.
//!   - a **wrong value**, or a **reserved option**, is an ERROR. An option that
//!     is accepted must ACT. Accepting `sourcemap: true` and quietly producing
//!     no source map would be the worst of the three possible behaviours.

import { isAbsolute, basename, extname, resolve as resolvePath, sep } from "node:path";

import {
  DEFAULT_ENTRY_FILE_NAMES,
  DEFAULT_EXTENSIONS,
  DEFAULT_OUT_DIR,
  type Config,
  type Mode,
} from "./config.js";
import { ConfigError } from "./load.js";
import type { ScopedAlias } from "./tsconfig.js";

export { ConfigError };

export interface ResolvedEntry {
  /** The output name: the basename for a string input, the KEY for an object. */
  name: string;
  /** Absolute path to the entry file. */
  file: string;
}

/** A config with every default applied and every path made absolute. */
export interface ResolvedConfig {
  mode: Mode;
  /**
   * The config file's directory — the project root as this build understands it.
   * Every relative path was resolved against it, and it bounds the tsconfig scan.
   */
  root: string;
  entries: ResolvedEntry[];
  outDir: string;
  entryFileNames: string;
  clean: boolean;
  minify: boolean;
  /** Already absolute — see {@link ResolveOptions.alias}. */
  alias: ScopedAlias[];
  extensions: string[];
  /** `false` = ignore tsconfigs; a path = use that one; `"auto"` = discover. */
  tsconfig: string | false | "auto";
  /** Set only when the CONFIG says so — it then wins over any tsconfig. */
  jsxImportSource?: string;
}

/**
 * Everything deliberately NOT implemented yet, and where it is going. The
 * message points at a version so the answer to "when?" is in the error itself,
 * not in an issue tracker you have to go find.
 */
const RESERVED: Record<string, { what: string; version: string }> = {
  sourcemap: { what: "sourcemap", version: "v0.4" },
  watch: { what: "watch", version: "v0.5" },
  "output.chunkFileNames": { what: "output.chunkFileNames", version: "v0.6" },
  "output.assetFileNames": { what: "output.assetFileNames", version: "v0.6" },
};

/**
 * Keys whose mere PRESENCE is the request, because they have no meaningful
 * "off" value — naming a chunk pattern only makes sense if you want chunks.
 *
 * The reserved BOOLEANS are not here on purpose: `sourcemap: false` and
 * `watch: false` describe exactly what zbundle does today, so writing them down
 * is legitimate. Only asking for the feature (`true`) is refused.
 */
const RESERVED_ON_PRESENCE = new Set(["output.chunkFileNames", "output.assetFileNames"]);

const ISSUES = "https://github.com/ztoolsmith/zbundle/issues";

const TOP_KEYS = ["mode", "input", "output", "resolve", "minify", "jsx", "tsconfig", "sourcemap", "watch"];
const JSX_KEYS = ["importSource"];
const OUTPUT_KEYS = ["dir", "format", "entryFileNames", "clean", "chunkFileNames", "assetFileNames"];
const RESOLVE_KEYS = ["alias", "extensions"];

function reserved(key: string): never {
  const r = RESERVED[key]!;
  throw new ConfigError(
    `${r.what}: reserved — planned for ${r.version}. Follow ${ISSUES}\n` +
      `  An option that is accepted must act; zbundle refuses rather than ignore it.`,
  );
}

/** Levenshtein distance, iterative and small — it only ever sees config keys. */
function distance(a: string, b: string): number {
  const prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  const cur = new Array<number>(b.length + 1);
  for (let i = 1; i <= a.length; i++) {
    cur[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      cur[j] = Math.min(cur[j - 1]! + 1, prev[j]! + 1, prev[j - 1]! + cost);
    }
    for (let j = 0; j <= b.length; j++) prev[j] = cur[j]!;
  }
  return prev[b.length]!;
}

/** The closest known key, when it is close enough to be worth naming. */
function suggest(key: string, known: string[]): string | null {
  let best: string | null = null;
  let bestD = Infinity;
  for (const k of known) {
    const d = distance(key.toLowerCase(), k.toLowerCase());
    if (d < bestD) {
      bestD = d;
      best = k;
    }
  }
  // Beyond a third of the length the "suggestion" is noise, not help.
  return best !== null && bestD <= Math.max(1, Math.ceil(key.length / 3)) ? best : null;
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function typeName(v: unknown): string {
  if (v === null) return "null";
  if (Array.isArray(v)) return "array";
  return typeof v;
}

function wrongType(path: string, v: unknown, expected: string): never {
  throw new ConfigError(`${path}: expected ${expected}, received ${typeName(v)} (${JSON.stringify(v)})`);
}

function checkKeys(obj: Record<string, unknown>, known: string[], prefix: string, warn: string[]): void {
  for (const key of Object.keys(obj)) {
    const full = prefix ? `${prefix}.${key}` : key;
    if (RESERVED_ON_PRESENCE.has(full)) reserved(full);
    if (known.includes(key)) continue;
    const hint = suggest(key, known);
    warn.push(`unknown option ${full}${hint ? ` — did you mean ${prefix ? `${prefix}.` : ""}${hint}?` : ""}`);
  }
}

/**
 * Turns whatever the config file evaluated to into a {@link ResolvedConfig}.
 *
 * `configDir` is the directory of the config FILE. Every relative path in the
 * config — inputs, `output.dir`, alias targets — is resolved against it, never
 * against the cwd. That is the classic trap: a config means the same thing
 * whatever directory you run the command from.
 */
export function validate(
  raw: unknown,
  configDir: string,
): { config: ResolvedConfig; warnings: string[] } {
  if (!isPlainObject(raw)) {
    const hint =
      typeName(raw) === "array"
        ? `\n  For several bundles, use one config with several inputs:\n` +
          `    input: { app: "src/app.ts", cli: "src/cli.ts" }`
        : typeName(raw) === "function"
          ? `\n  A function config is not supported: call defineConfig with the object itself.`
          : "";
    throw new ConfigError(
      `the config must export an object, received ${typeName(raw)}\n` +
        `  expected: export default defineConfig({ input: "src/index.ts" })${hint}`,
    );
  }
  const warnings: string[] = [];
  checkKeys(raw, TOP_KEYS, "", warnings);
  const c = raw as Config & Record<string, unknown>;

  // ---- mode ----
  let mode: Mode = "development";
  if (c.mode !== undefined) {
    if (c.mode !== "development" && c.mode !== "production") {
      wrongType("mode", c.mode, `"development" | "production"`);
    }
    mode = c.mode;
  }

  // ---- input (the only required key) ----
  if (c.input === undefined) {
    throw new ConfigError(`input: required — nothing to bundle\n  expected: input: "src/index.ts"`);
  }
  const entries = readInput(c.input, configDir);
  if (entries.length === 0) wrongType("input", c.input, "at least one entry");

  // ---- output ----
  let outDir = resolvePath(configDir, DEFAULT_OUT_DIR);
  let entryFileNames = DEFAULT_ENTRY_FILE_NAMES;
  let clean = false;
  if (c.output !== undefined) {
    if (!isPlainObject(c.output)) wrongType("output", c.output, "object");
    checkKeys(c.output, OUTPUT_KEYS, "output", warnings);
    const o = c.output as Record<string, unknown>;
    if (o.dir !== undefined) {
      if (typeof o.dir !== "string") wrongType("output.dir", o.dir, "string");
      // An empty string resolves to the config's own directory, which would make
      // the bundle land ON TOP of the sources. `"."` says that explicitly if it
      // is really what someone wants.
      if (o.dir === "") {
        throw new ConfigError(
          `output.dir: cannot be empty — it would resolve to the config's own directory\n` +
            `  and write the bundles next to (or over) your sources. Use "." if you mean it.`,
        );
      }
      outDir = isAbsolute(o.dir) ? o.dir : resolvePath(configDir, o.dir);
    }
    if (o.format !== undefined && o.format !== "esm") {
      throw new ConfigError(
        `output.format: ${JSON.stringify(o.format)} — only "esm" is supported in v1.\n` +
          `  "iife" exists on the command line (\`zbundle <entry> -f iife\`); "cjs"/"umd" are planned for v0.6.\n` +
          `  Follow ${ISSUES}`,
      );
    }
    if (o.entryFileNames !== undefined) {
      if (typeof o.entryFileNames !== "string") {
        wrongType("output.entryFileNames", o.entryFileNames, "string");
      }
      if (o.entryFileNames === "") {
        throw new ConfigError(`output.entryFileNames: cannot be empty — every bundle needs a file name`);
      }
      if (isAbsolute(o.entryFileNames)) {
        throw new ConfigError(
          `output.entryFileNames: ${JSON.stringify(o.entryFileNames)} is absolute — it is a name\n` +
            `  RELATIVE to output.dir, not a path. Set output.dir instead.`,
        );
      }
      checkPlaceholders(o.entryFileNames);
      entryFileNames = o.entryFileNames;
    }
    if (o.clean !== undefined) {
      if (typeof o.clean !== "boolean") wrongType("output.clean", o.clean, "boolean");
      clean = o.clean;
    }
  }

  // ---- resolve ----
  const alias: ScopedAlias[] = [];
  let extensions = [...DEFAULT_EXTENSIONS];
  if (c.resolve !== undefined) {
    if (!isPlainObject(c.resolve)) wrongType("resolve", c.resolve, "object");
    checkKeys(c.resolve, RESOLVE_KEYS, "resolve", warnings);
    const r = c.resolve as Record<string, unknown>;
    if (r.alias !== undefined) {
      if (!isPlainObject(r.alias)) wrongType("resolve.alias", r.alias, "object");
      for (const [from, to] of Object.entries(r.alias)) {
        if (typeof to !== "string") wrongType(`resolve.alias.${from}`, to, "string");
        if (from === "") throw new ConfigError(`resolve.alias: an alias key cannot be empty`);
        // THE trap: relative to the config file, not to the cwd.
        const abs = isAbsolute(to) ? to : resolvePath(configDir, to);
        // `path.resolve` STRIPS a trailing separator, but an alias is a raw
        // prefix substitution: with `'#lib/' -> './src/'`, losing the slash
        // turns `#lib/x.js` into `srcx.js`. The user's trailing separator is
        // part of what they wrote, so it is preserved.
        const keepsSlash = /[\\/]$/.test(to) && !/[\\/]$/.test(abs);
        // An explicit alias governs the WHOLE build (empty scope) and is a
        // prefix rule — that is what `resolve.alias` has always meant.
        alias.push({ from, to: keepsSlash ? abs + sep : abs, exact: false, scope: "" });
      }
    }
    if (r.extensions !== undefined) {
      if (!Array.isArray(r.extensions)) wrongType("resolve.extensions", r.extensions, "array of strings");
      r.extensions.forEach((e, i) => {
        if (typeof e !== "string") wrongType(`resolve.extensions[${i}]`, e, "string");
        if (!e.startsWith(".")) {
          throw new ConfigError(`resolve.extensions[${i}]: ${JSON.stringify(e)} must start with a dot (".ts")`);
        }
      });
      if (r.extensions.length === 0) {
        throw new ConfigError(`resolve.extensions: cannot be empty — nothing would ever resolve`);
      }
      extensions = r.extensions as string[];
    }
  }

  // ---- minify (its default is mode's ONLY effect) ----
  let minify = mode === "production";
  if (c.minify !== undefined) {
    if (typeof c.minify !== "boolean") wrongType("minify", c.minify, "boolean");
    minify = c.minify;
  }

  // ---- tsconfig ----
  let tsconfig: string | false | "auto" = "auto";
  if (c.tsconfig !== undefined) {
    if (c.tsconfig === false) tsconfig = false;
    else if (typeof c.tsconfig === "string") {
      if (c.tsconfig === "") throw new ConfigError(`tsconfig: cannot be empty — use false to disable it`);
      tsconfig = isAbsolute(c.tsconfig) ? c.tsconfig : resolvePath(configDir, c.tsconfig);
    } else if (c.tsconfig === true) {
      throw new ConfigError(
        `tsconfig: true is not a value — omit the key for auto-detection, or give a path`,
      );
    } else wrongType("tsconfig", c.tsconfig, "string | false");
  }

  // ---- jsx ----
  let jsxImportSource: string | undefined;
  if (c.jsx !== undefined) {
    if (!isPlainObject(c.jsx)) wrongType("jsx", c.jsx, "object");
    checkKeys(c.jsx, JSX_KEYS, "jsx", warnings);
    const j = c.jsx as Record<string, unknown>;
    if (j.importSource !== undefined) {
      if (typeof j.importSource !== "string") wrongType("jsx.importSource", j.importSource, "string");
      if (j.importSource === "") throw new ConfigError(`jsx.importSource: cannot be empty`);
      jsxImportSource = j.importSource;
    }
  }

  // ---- the reserved booleans ----
  // `false` is the current behaviour, so it is accepted; only asking for the
  // feature is refused.
  if (c.sourcemap === true) reserved("sourcemap");
  if (c.sourcemap !== undefined && typeof c.sourcemap !== "boolean") {
    wrongType("sourcemap", c.sourcemap, "boolean");
  }
  if (c.watch === true) reserved("watch");
  if (c.watch !== undefined && typeof c.watch !== "boolean") wrongType("watch", c.watch, "boolean");

  return {
    config: { mode, root: configDir, entries, outDir, entryFileNames, clean, minify, alias, extensions, tsconfig, jsxImportSource },
    warnings,
  };
}

/** `[name]` is the only placeholder; anything else is a typo we must not eat. */
function checkPlaceholders(pattern: string): void {
  for (const m of pattern.matchAll(/\[(\w+)\]/g)) {
    if (m[1] !== "name") {
      throw new ConfigError(
        `output.entryFileNames: unknown placeholder [${m[1]}] — only [name] exists in v1\n` +
          `  [hash]/[format] are planned alongside code splitting (v0.6). Follow ${ISSUES}`,
      );
    }
  }
}

/** The three input shapes, normalized to one list of named entries. */
function readInput(input: unknown, configDir: string): ResolvedEntry[] {
  const one = (file: string, name?: string): ResolvedEntry => {
    if (file === "") {
      throw new ConfigError(
        `input: an entry path cannot be empty${name !== undefined ? ` (key ${JSON.stringify(name)})` : ""}`,
      );
    }
    const resolved = name ?? basename(file, extname(file));
    if (resolved === "") {
      throw new ConfigError(
        `input: an entry name cannot be empty — it would produce a file with no name.\n` +
          `  Name it with the object form: input: { app: ${JSON.stringify(file)} }`,
      );
    }
    return { name: resolved, file: isAbsolute(file) ? file : resolvePath(configDir, file) };
  };
  if (typeof input === "string") return [one(input)];
  if (Array.isArray(input)) {
    input.forEach((v, i) => {
      if (typeof v !== "string") wrongType(`input[${i}]`, v, "string");
    });
    return (input as string[]).map((f) => one(f));
  }
  if (isPlainObject(input)) {
    return Object.entries(input).map(([name, file]) => {
      if (typeof file !== "string") wrongType(`input.${name}`, file, "string");
      return one(file, name);
    });
  }
  return wrongType("input", input, "string | string[] | Record<string, string>");
}
