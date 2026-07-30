//! Reading `tsconfig.json` — the little a STRIPPER is allowed to care about.
//!
//! **The closed list.** zbundle erases types, it never checks them, so it reads
//! exactly four things and ignores everything else in silence:
//!
//!   - `baseUrl` + `paths`  -> resolution aliases
//!   - `jsx`                -> refused when it says `preserve`
//!   - `jsxImportSource`    -> handed to zcompiler's JSX transform
//!
//! `target`/`module` are meaningless here (there is no downleveling),
//! `strict`/`types`/`lib` belong to `tsc`, and `references`/`composite` are a
//! monorepo chantier of their own. Ignoring them is the CONTRACT, not an
//! oversight: a config option zbundle claims to read must change what it does.
//!
//! **Per file, not per build.** A monorepo has one tsconfig per package, each
//! with its own `paths`, and a module must be resolved by the one that governs
//! IT. So each discovered tsconfig produces aliases SCOPED to its directory, and
//! `resolver.zig` picks the nearest scope for each importer.

import { createRequire } from "node:module";
import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { dirname, isAbsolute, join, resolve as resolvePath, sep } from "node:path";

import { parseJsonc, JsoncError } from "./jsonc.js";
import { codeframe } from "./codeframe.js";
import { ConfigError } from "./load.js";

/** One alias as `resolver.zig` wants it: absolute target, scoped, exact or prefix. */
export interface ScopedAlias {
  from: string;
  to: string;
  exact: boolean;
  scope: string;
}

export interface TsconfigInfo {
  /** The tsconfig that governs, after the `extends` chain was walked. */
  file: string;
  aliases: ScopedAlias[];
  jsxImportSource?: string;
  warnings: string[];
}

/** Everything read from one file, plus WHERE each value came from. */
interface Options {
  baseUrl?: { value: string; dir: string };
  paths?: { value: Record<string, unknown>; dir: string };
  jsx?: { value: string; file: string };
  jsxImportSource?: { value: string };
}

const TSCONFIG = "tsconfig.json";

/**
 * The nearest `tsconfig.json` at or above `dir`, or null.
 *
 * Cached **per directory** because it is asked once per module, and a deep tree
 * asks the same question about the same ancestors over and over.
 */
export function findTsconfig(dir: string, cache: Map<string, string | null>): string | null {
  const cached = cache.get(dir);
  if (cached !== undefined) return cached;

  const chain: string[] = [];
  let current = dir;
  let found: string | null = null;
  for (;;) {
    const hit = cache.get(current);
    if (hit !== undefined) {
      found = hit;
      break;
    }
    chain.push(current);
    const candidate = join(current, TSCONFIG);
    if (existsSync(candidate)) {
      found = candidate;
      break;
    }
    const parent = dirname(current);
    if (parent === current) break; // filesystem root
    current = parent;
  }
  // Every directory walked shares the answer: one lookup, many hits.
  for (const d of chain) cache.set(d, found);
  return found;
}

/**
 * Reads one tsconfig and everything it extends, child winning.
 *
 * `extends` targets are resolved against the file DOING the extending — a
 * relative path, or a package (`@repo/tsconfig`, which may or may not name the
 * `.json` itself). A cycle is an error naming the loop rather than a hang.
 */
function readChain(file: string, seen: string[] = []): Options {
  const abs = resolvePath(file);
  if (seen.includes(abs)) {
    throw new ConfigError(
      `tsconfig: circular extends\n    ${[...seen, abs].map((f) => shortish(f)).join("\n -> ")}`,
    );
  }
  if (!existsSync(abs)) {
    throw new ConfigError(`tsconfig: extends target not found: ${shortish(abs)}`);
  }

  let raw: unknown;
  try {
    raw = parseJsonc(readFileSync(abs, "utf8"), shortish(abs));
  } catch (err) {
    if (err instanceof JsoncError) {
      // The message already carries file:line:column; the frame shows the line.
      const text = readFileSync(abs, "utf8");
      const detail = err.message.replace(/^\S+?:\d+:\d+: /, "");
      throw new ConfigError(
        `tsconfig: ${detail}\n  ${codeframe(shortish(abs), text, err.line, err.column)}\n` +
          `  A tsconfig may hold comments and trailing commas, but it is still JSON.`,
      );
    }
    throw err;
  }
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    throw new ConfigError(`tsconfig: ${shortish(abs)} must contain an object`);
  }

  const node = raw as Record<string, unknown>;
  const dir = dirname(abs);

  // The parent first, so the child can overwrite it.
  let merged: Options = {};
  const ext = node.extends;
  if (typeof ext === "string") {
    merged = readChain(resolveExtends(ext, abs), [...seen, abs]);
  } else if (Array.isArray(ext)) {
    // TS 5.0 allows a list, applied left to right.
    for (const one of ext) {
      if (typeof one !== "string") continue;
      merged = { ...merged, ...readChain(resolveExtends(one, abs), [...seen, abs]) };
    }
  }

  const co = isRecord(node.compilerOptions) ? node.compilerOptions : {};
  // Each value REMEMBERS its file: `paths` are relative to the tsconfig that
  // declared them, not to the one at the end of the chain. That is the trap.
  if (typeof co.baseUrl === "string") merged.baseUrl = { value: co.baseUrl, dir };
  if (isRecord(co.paths)) merged.paths = { value: co.paths, dir };
  if (typeof co.jsx === "string") merged.jsx = { value: co.jsx, file: abs };
  if (typeof co.jsxImportSource === "string") merged.jsxImportSource = { value: co.jsxImportSource };
  return merged;
}

/** `./x`, `/x`, or a package — the three shapes TypeScript accepts. */
function resolveExtends(spec: string, from: string): string {
  if (spec.startsWith(".") || isAbsolute(spec)) {
    const target = resolvePath(dirname(from), spec);
    // `extends: "./base"` means `./base.json`; a directory means its tsconfig.
    if (existsSync(target) && statSync(target).isDirectory()) return join(target, TSCONFIG);
    if (existsSync(target)) return target;
    return target.endsWith(".json") ? target : `${target}.json`;
  }
  const req = createRequire(from);
  for (const candidate of [spec, `${spec}/${TSCONFIG}`]) {
    try {
      return req.resolve(candidate);
    } catch {
      /* try the next shape */
    }
  }
  throw new ConfigError(
    `tsconfig: cannot resolve extends ${JSON.stringify(spec)} from ${shortish(from)}`,
  );
}

/**
 * The canonical form of a path, when it exists.
 *
 * **The scope has to be canonical.** `resolver.zig` compares it against the
 * directory of the importing module, and those come from `realPath` — symlinks
 * followed, case corrected. A scope built from a path that was never
 * canonicalised (on macOS, `/var` vs `/private/var`; anywhere, a symlinked
 * checkout) would simply never match, and the tsconfig would silently do
 * nothing. Silence is the failure mode this project refuses.
 */
function canonical(p: string): string {
  try {
    return realpathSync(p);
  } catch {
    return resolvePath(p);
  }
}

/**
 * Turns a resolved tsconfig into what the rest of the build understands.
 *
 * Every path is made absolute here, against the directory of the tsconfig that
 * DECLARED it — not the cwd, not the importing file.
 */
export function translate(file: string): TsconfigInfo {
  const opts = readChain(file);
  const scope = canonical(dirname(resolvePath(file)));
  const warnings: string[] = [];
  const aliases: ScopedAlias[] = [];

  if (opts.paths) {
    // TS 4.1+: `paths` without `baseUrl` is relative to the tsconfig itself.
    const base = opts.baseUrl
      ? resolvePath(opts.baseUrl.dir, opts.baseUrl.value)
      : opts.paths.dir;

    for (const [key, targets] of Object.entries(opts.paths.value)) {
      // A malformed entry is skipped — validating a tsconfig is `tsc`'s job,
      // not ours — but never in SILENCE: the only symptom would otherwise be a
      // "cannot resolve" further down, with nothing pointing back to here.
      if (!Array.isArray(targets)) {
        warnings.push(
          `tsconfig paths ${JSON.stringify(key)} must map to an ARRAY of targets; entry ignored`,
        );
        continue;
      }
      if (targets.length === 0) {
        warnings.push(`tsconfig paths ${JSON.stringify(key)} has no target; entry ignored`);
        continue;
      }
      const list = targets.filter((t): t is string => typeof t === "string");
      if (list.length === 0) {
        warnings.push(
          `tsconfig paths ${JSON.stringify(key)} lists no string target; entry ignored`,
        );
        continue;
      }
      if (list.length > 1) {
        // v1 keeps the FIRST and says so. Real fallback would mean trying each
        // target in turn and remembering which one answered — resolution state
        // the Zig resolver does not carry today.
        warnings.push(
          `tsconfig paths ${JSON.stringify(key)} lists ${list.length} targets; ` +
            `zbundle uses the first (${JSON.stringify(list[0])}) and ignores the rest`,
        );
      }
      const target = list[0]!;
      const star = key.indexOf("*");
      if (star === -1) {
        // No wildcard: an EXACT mapping. `"jquery"` must not catch `jquery-ui`.
        aliases.push({ from: key, to: canonical(resolvePath(base, target)), exact: true, scope });
        continue;
      }
      if (key.indexOf("*", star + 1) !== -1) {
        warnings.push(`tsconfig paths ${JSON.stringify(key)} has more than one *; ignored`);
        continue;
      }
      // `'@/*': ['./src/*']` -> prefix `'@/'` becomes `<base>/src/`. Both sides
      // keep everything before their `*`, which is exactly a prefix rule.
      const prefix = key.slice(0, star);
      const targetStar = target.indexOf("*");
      const targetPrefix = targetStar === -1 ? target : target.slice(0, targetStar);
      let to = canonical(resolvePath(base, targetPrefix));
      // `resolvePath` strips a trailing separator; the substitution is textual,
      // so it has to come back or `@/x` would become `srcx`.
      if (/[\\/]$/.test(targetPrefix) && !/[\\/]$/.test(to)) to += sep;
      aliases.push({ from: prefix, to, exact: false, scope });
    }
  }

  if (opts.jsx) {
    const value = opts.jsx.value;
    if (value === "preserve") {
      throw new ConfigError(
        `tsconfig: "jsx": "preserve" is not supported — and will not be.\n` +
          `    ${shortish(opts.jsx.file)}\n` +
          `  zbundle emits JavaScript; preserving JSX would mean emitting something\n` +
          `  another tool still has to compile. Use "react-jsx", or take JSX out of the build.`,
      );
    }
    if (value === "react" || value === "react-native") {
      // The classic runtime is not something zcompiler implements, and saying
      // nothing would leave a real difference from `tsc` unmentioned.
      warnings.push(
        `tsconfig "jsx": ${JSON.stringify(value)} selects the classic runtime; ` +
          `zbundle always compiles with the automatic one (jsx()/jsxs()). ` +
          `The output works with React 17+; set "jsx": "react-jsx" to silence this.`,
      );
    }
  }

  return { file: resolvePath(file), aliases, jsxImportSource: opts.jsxImportSource?.value, warnings };
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** Paths in messages are read by humans; absolute ones rarely help. */
function shortish(p: string): string {
  const cwd = process.cwd();
  return p.startsWith(cwd + sep) ? p.slice(cwd.length + 1) : p;
}
