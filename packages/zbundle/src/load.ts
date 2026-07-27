//! Finding and LOADING a config file. Nothing here judges the contents —
//! that is `validate.ts`. This file answers two questions only: which file, and
//! what object does it evaluate to.

import { createRequire } from "node:module";
import { existsSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import process from "node:process";

/**
 * The lookup order, and it is a documented contract: TypeScript first, because
 * a typed config is the point of `defineConfig`.
 */
export const CONFIG_NAMES = [
  "zbundle.config.ts",
  "zbundle.config.mts",
  "zbundle.config.js",
  "zbundle.config.mjs",
] as const;

/**
 * A REAL dynamic import, surviving the CommonJS emit.
 *
 * The package is CJS (`require("zbundle")` has to keep working), so `tsc` would
 * happily downlevel a literal `import()` into `require()` — which cannot load an
 * ESM config file at all. Going through `new Function` keeps a genuine
 * `import()` in the output. The usual objection (bundlers cannot analyse it)
 * does not apply: this is a CLI reading a path known only at runtime.
 */
const dynamicImport = new Function("specifier", "return import(specifier)") as (
  s: string,
) => Promise<Record<string, unknown>>;

export class ConfigError extends Error {}

/**
 * The config file to use, or `null` when there is none.
 *
 * `explicit` (from `--config`) is taken as given and MUST exist: asking for a
 * file that is not there is an error, never a silent fallback to the defaults.
 */
export function findConfigFile(cwd: string, explicit?: string): string | null {
  if (explicit) {
    const file = isAbsolute(explicit) ? explicit : resolve(cwd, explicit);
    if (!existsSync(file)) throw new ConfigError(`config file not found: ${explicit}`);
    return file;
  }
  for (const name of CONFIG_NAMES) {
    const file = join(cwd, name);
    if (existsSync(file)) return file;
  }
  return null;
}

/**
 * Evaluates a config file and returns its default export (or the module itself
 * when there is no default — a plain `module.exports = {}` is fine too).
 *
 * TypeScript is loaded by Node's own type stripping (22.6+), which needs no
 * dependency at all. When that fails — an older Node, or a config using syntax
 * stripping cannot erase, such as `enum` — we fall back to **jiti** if the
 * project has it. jiti is deliberately NOT a dependency: zbundle ships with
 * zero runtime dependencies, and the overwhelmingly common case needs none.
 */
export async function loadConfigModule(file: string): Promise<unknown> {
  try {
    const mod = await dynamicImport(pathToFileURL(file).href);
    return (mod as { default?: unknown }).default ?? mod;
  } catch (err) {
    if (!/\.m?ts$/.test(file)) throw err;
    const viaJiti = await tryJiti(file);
    if (viaJiti !== undefined) return viaJiti;
    throw new ConfigError(
      `cannot load ${file}\n` +
        `  ${err instanceof Error ? err.message : String(err)}\n` +
        `  TypeScript configs need Node 22.6+ (native type stripping) — you are on ${process.version}.\n` +
        `  Either upgrade Node, install jiti (\`npm i -D jiti\`), or rename the file to zbundle.config.mjs.`,
    );
  }
}

/**
 * jiti, resolved from the CONFIG's project rather than from zbundle's own
 * `node_modules`: it is the user who installs it, so it is their tree that must
 * be searched. Returns `undefined` when jiti is simply absent, which is not an
 * error — it is the normal case.
 */
async function tryJiti(file: string): Promise<unknown | undefined> {
  try {
    const req = createRequire(file);
    const jitiPath = req.resolve("jiti");
    const mod = (await dynamicImport(pathToFileURL(jitiPath).href)) as {
      default?: unknown;
      createJiti?: unknown;
    };
    const factory = (mod.createJiti ?? mod.default ?? mod) as (
      from: string,
      opts?: unknown,
    ) => ((id: string) => unknown) & { import?: (id: string, o?: unknown) => Promise<unknown> };
    const jiti = factory(file, { interopDefault: true });
    if (typeof jiti.import === "function") return await jiti.import(file, { default: true });
    const loaded = jiti(file) as { default?: unknown };
    return loaded?.default ?? loaded;
  } catch {
    return undefined;
  }
}
