//! The PUBLIC config API — the types a user writes against, and nothing else.
//!
//! This file is the package's typed surface (`zbundle/config`). It holds no
//! logic on purpose: types, defaults, and `defineConfig`, which is the typed
//! identity function. Loading lives in `load.ts`, checking in `validate.ts`,
//! orchestration in `build.ts`.
//!
//! **The boundary this layer serves** (the rule for the whole package): what is
//! decided *per module* belongs to Zig, what is decided *per build* belongs
//! here. Resolving a specifier, walking the graph, linking, shaking — per
//! module, all Zig. Reading a config file, expanding an input, naming an output
//! file, cleaning a directory — per build, all TypeScript. This layer
//! ORCHESTRATES; it never computes.

/**
 * The build mode.
 *
 * **In v1 its ONLY effect is the default value of `minify`** — nothing else.
 * No `define`, no `process.env.NODE_ENV` injection, no conditional exports
 * resolution. Saying so explicitly matters: `mode` looks like it does much more
 * in other bundlers, and a silent difference would be worse than a missing
 * feature.
 */
export type Mode = "development" | "production";

/** The only output format v1 emits. The type says it, so does the validator. */
export type Format = "esm";

/** How a source map is delivered. `false` is the default: nothing at all. */
export type SourcemapMode = boolean | "inline" | "hidden";

/**
 * The long form, for the two things a mode alone cannot say.
 *
 * Writing the object at all means you want a map, so `mode` defaults to `true`.
 */
export interface SourcemapOptions {
  mode?: SourcemapMode;
  /**
   * Prefixed to every entry of `sources` by the consumer.
   *
   * Useful when the map is served from somewhere the relative paths do not
   * reach — `'/@src/'`, `'https://example.com/src/'`. Left out entirely when
   * unset: an empty `sourceRoot` is not the same as no `sourceRoot`.
   */
  sourceRoot?: string;
  /**
   * Embed the sources in the map. Default: `true` — debugging then needs no
   * access to the original tree, which is the whole point of shipping a map.
   *
   * `false` makes a much smaller map, for setups that serve the sources
   * themselves.
   */
  sourcesContent?: boolean;
}

export interface JsxOptions {
  /**
   * What the JSX transform imports its runtime from: `"react"` gives
   * `react/jsx-runtime`, `"preact"` gives `preact/jsx-runtime`. Defaults to the
   * tsconfig's `jsxImportSource`, then to `"react"`.
   */
  importSource?: string;
}

export interface ResolveOptions {
  /**
   * Prefix aliases: `{ '@': './src' }` turns `'@/x'` into `'./src/x'`.
   *
   * **Exact prefix substitution** — no regex, no multiple fallback. A relative
   * target is resolved against the directory of the CONFIG FILE, never the cwd:
   * a config describes paths relative to where it lives, so moving the working
   * directory must not change what it means.
   *
   * An aliased specifier is never external: if it does not exist on disk, the
   * build fails rather than silently leaving an unresolved import in the bundle.
   */
  alias?: Record<string, string>;
  /**
   * Try order for an omitted extension. Order is meaning, not preference:
   * `.ts` before `.js` is what makes a TS project see its source rather than a
   * stale compiled sibling. Defaults to {@link DEFAULT_EXTENSIONS}.
   */
  extensions?: string[];
}

export interface OutputOptions {
  /** Where bundles are written. Default: `'dist'`. */
  dir?: string;
  /** Only `'esm'` in v1. Anything else is refused, with the target version. */
  format?: Format;
  /**
   * The output file name pattern. `[name]` is the ONLY placeholder, and it is
   * the entry's name: the basename for a string/array input, the KEY for an
   * object input. A key containing `/` (`'cli/index'`) creates the
   * subdirectories under `dir`. Default: `'[name].js'`.
   */
  entryFileNames?: string;
  /** Empty `dir` before emitting. Default: `false`. */
  clean?: boolean;
}

export interface Config {
  /** Default: `'development'`. Its only v1 effect is the `minify` default. */
  mode?: Mode;
  /**
   * What to bundle. Three shapes:
   *   - `'src/index.ts'` — one bundle, named after the file;
   *   - `['a.ts', 'b.ts']` — N INDEPENDENT bundles (no shared chunk: that is
   *     code splitting, and it is not v1);
   *   - `{ main: 'src/index.ts', 'cli/index': 'src/cli.ts' }` — the same, with
   *     the output names chosen by key.
   * Relative paths are resolved against the config file's directory.
   */
  input: string | string[] | Record<string, string>;
  output?: OutputOptions;
  resolve?: ResolveOptions;
  /**
   * Shorten cross-module names. Default: `mode === 'production'`.
   *
   * **What it really does**, so nobody is surprised: it renames top-level
   * bindings to short names across the whole bundle, with the guarantee that a
   * short name never shadows a local or captures a global. It does NOT strip
   * whitespace or shorten properties — the emitted JS stays indented and
   * readable. Compact output needs a compact printer in zcompiler; that work
   * belongs downstairs, not here.
   */
  minify?: boolean;
  /** JSX settings. Overrides whatever the tsconfig said. */
  jsx?: JsxOptions;
  /**
   * How to use the project's `tsconfig.json`.
   *
   *   - omitted (the default) — find the nearest one for every file and read
   *     `baseUrl`/`paths`, `jsx` and `jsxImportSource` from it;
   *   - a path — use exactly that file;
   *   - `false` — ignore tsconfigs entirely.
   *
   * Only those three settings are ever read. `target`, `module`, `strict`,
   * `lib`, `types`, `references`… are ignored **by contract**: zbundle erases
   * types, it never checks them, and an option it claims to read must change
   * what it does. Type-checking stays `tsc`'s job.
   *
   * Anything written here wins: `resolve.alias` merges OVER the tsconfig
   * `paths`, and an explicit `jsx.importSource` overrides the tsconfig's.
   */
  tsconfig?: string | false;
  /**
   * Emit a source map v3 — a position in the bundle points back at the exact
   * character of the original `.ts`.
   *
   *   - `false` (default) — no map, and not one extra byte in the bundle;
   *   - `true` — a `.js.map` beside the bundle, plus the `sourceMappingURL`
   *     comment that points at it;
   *   - `'inline'` — the map as a base64 data URL inside the bundle itself;
   *   - `'hidden'` — the `.map` is written but NO comment is added, for the
   *     setups that upload it separately.
   *
   * The chain is followed end to end: TS/TSX source -> type stripping and JSX
   * lowering -> scope hoisting and cross-module renaming -> printed output. A
   * renamed binding still points at the identifier it came from.
   */
  sourcemap?: SourcemapMode | SourcemapOptions;
  /** RESERVED — setting it to `true` is an error that names the target version. */
  watch?: boolean;
}

/** The resolver's extension table, mirrored here as the documented default. */
export const DEFAULT_EXTENSIONS: readonly string[] = [".ts", ".tsx", ".js", ".jsx", ".mjs"];

/** Embedded by default: debugging then needs no access to the original tree. */
export const DEFAULT_SOURCEMAP_CONTENT = true;

export const DEFAULT_OUT_DIR = "dist";
export const DEFAULT_ENTRY_FILE_NAMES = "[name].js";

/**
 * The typed identity function. It returns its argument untouched; its whole job
 * is to give an editor something to check a `zbundle.config.ts` against.
 *
 * ```ts
 * import { defineConfig } from "zbundle/config";
 * export default defineConfig({ input: "src/index.ts" });
 * ```
 */
export function defineConfig(config: Config): Config {
  return config;
}
