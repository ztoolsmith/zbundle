# Changelog

All notable changes to zbundle. Format inspired by
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[SemVer](https://semver.org/).

## [0.3.0] — 2026-07-27

**`tsconfig.json` support.** zbundle now takes resolution and JSX settings from
the project's tsconfig, like rolldown and esbuild — as a STRIPPER does, which
means a short and closed list.

### Added

- **`baseUrl` + `paths` become resolution aliases.** A wildcard entry
  (`"@/*": ["./src/*"]`) is a prefix; an entry without one (`"jquery":
  ["./vendor/jq.js"]`) is an **exact** mapping, so it cannot swallow
  `jquery-ui`.

- **Per FILE, not per build.** Each tsconfig produces aliases scoped to its own
  directory, and the nearest scope wins. Two packages of a monorepo can map the
  same `#own/` to their own `src` — something a single global alias table cannot
  express.

- **`jsxImportSource` is honoured.** It was never wired: the JSX transform always
  imported from `react`, whatever the tsconfig said.

- **`tsconfig: string | false`** in the config — force a file, or ignore
  tsconfigs entirely. Omitted means auto-detection.

- **`jsx.importSource`** in the config, which overrides the tsconfig's.

- **JSONC is parsed properly** — comments and trailing commas, which every real
  tsconfig has. A hand-written parser, not a comment-stripping regex: `"http://x"`
  inside a string must keep its tail. Errors carry `file:line:column`.

- **`extends` chains** are resolved (relative, directory, npm package), merged
  child-first, with a circular chain reported as the loop it is. Each value is
  resolved against the file that DECLARED it — `paths` in an extended config are
  relative to that config, not to the one at the end of the chain.

### The closed list

`baseUrl`/`paths`, `jsx`, `jsxImportSource`. **Everything else is ignored on
purpose**: `target`/`module` (there is no downleveling), `strict`/`lib`/`types`
(that is `tsc`'s job), `allowJs`/`checkJs`, `references`/`composite`. An option
zbundle claimed to read would have to change what it does.

`"jsx": "preserve"` is refused — and always will be: zbundle emits JavaScript,
and preserving JSX would mean emitting something another tool still has to
compile. `"jsx": "react"` (the classic runtime) is not refused but **warned
about**: zbundle always compiles with the automatic runtime, so the output
differs from what `tsc` would emit.

**Anything written in `zbundle.config.ts` wins**: `resolve.alias` merges over
the tsconfig `paths`, and `jsx.importSource` overrides `jsxImportSource`.

Multiple `paths` targets (`["./a/*", "./b/*"]`) keep the **first**, and say so:
real fallback would mean trying each target in turn, which is resolution state
the resolver does not carry.

### Fixed

- **A bare side-effect import of an external was silently dropped.**
  `import 'some-polyfill'` declares no binding, so nothing registered it, and it
  vanished from the bundle — while evaluating the module is the entire point of
  that syntax. Internal ones (`import './polyfill'`) were always kept; only
  externals were affected. An external whose named imports all die still drops
  out, which is the correct contrast.

### Changed

- The reserved options move one version along, now that v0.3 is taken:
  `sourcemap` v0.4, `watch` v0.5, `chunkFileNames`/`assetFileNames` v0.6.

### Verified

93 Zig tests (+9), 142 Node tests (+16), **25/25** in the playground judge — four
new projects, and the twenty-one existing ones unchanged. The new ones are built
through the command, config file included: `tsconfig-paths` (the twin of
`config-alias`, with no `resolve.alias` anywhere), `tsconfig-extends` (a
two-level chain), `tsconfig-jsx` (a **preact** shim, so the import source proves
something), and `tsconfig-monorepo` (two packages, the same key, different
answers — a broken scope shows up immediately).

## [0.2.3] — 2026-07-27

The rule this project applies to config options — **an option that is accepted
must ACT** — now applies to the command line itself.

### Fixed

- **Seven command-line options were accepted and then ignored.** `zbundle build`
  swallowed `-o`, `-f`, `--graph` and `--watch` without a word, and the one-shot
  form did the same with `--config` and `--out-dir` — every one of them exiting
  0 as if it had worked. Each is now refused, naming the form it belongs to:

  ```
  ✘ -o/--out does not apply here.
    `build` writes into output.dir, named by output.entryFileNames.
    For a single file on a path you choose: zbundle <entry> -o <file>
  ```

  `--watch` on `build` names the version it is planned for (v0.4) and points at
  the interim one-shot watch, rather than pretending the flag did something.

- **A config using non-erasable TypeScript blamed the wrong thing.** An `enum`
  (or `namespace`, or parameter properties) cannot be handled by type stripping
  at all, but the error read *"TypeScript configs need Node 22.6+ — you are on
  v24.15.0"*, which is both untrue and useless. The two causes are now told
  apart, and each names its own way out.

### Added

- **`zbundle build --dead`** lists what tree-shaking removed, bundle by bundle.
  It was the one flag among the seven worth implementing rather than refusing.

### Verified

The **jiti fallback was exercised for real** for the first time — jiti 2.7.0
installed in a throwaway project, with a config using an `enum`: the native strip
fails, jiti takes over, and the config's `mode: "production"` is honoured end to
end. Until now that path had been written but never run.

126 Node tests (+8), 84 Zig tests, 21/21 in the playground judge.

## [0.2.2] — 2026-07-27

Everything a config file can say, walked one key at a time — including the paths
it can name. Six ways to write outside the declared output, or over your own
sources, are now refused.

### Fixed

- **Nothing escapes `output.dir` any more.** A `..` in an input KEY
  (`input: { "../escape": "m.js" }`) or in `output.entryFileNames`
  (`"../escape.js"`) wrote the bundle *outside* the directory the config
  declared, silently. `output.dir` is the contract: everything the build produces
  lives under it. A name may still create subdirectories (`"cli/deep/index"`); it
  may just never leave.

- **A bundle is never written over a source file.** `output.dir: ""` resolved to
  the config's own directory, so `input: "m.js"` with the default
  `[name].js` replaced `m.js` with its own bundle — and there is no undo for
  that. Empty `output.dir` is now refused outright, and any output path that
  lands on one of the build's own inputs is refused too, whatever produced it.

- **Empty names are refused** instead of producing nonsense: `output.dir: ""`,
  `output.entryFileNames: ""` (which wrote a file named after the directory), an
  empty input key (which produced `dist/.js`), and an empty input path (whose
  error message pointed at the wrong thing).

- **An absolute `output.entryFileNames`** (`"/tmp/x.js"`) was silently treated as
  relative to `output.dir`. It is a name, not a path, and now says so.

- **`output.dir` pointing at an existing FILE** surfaced a raw
  `EEXIST: file already exists, mkdir …`. It now names the file and what to do.

### Changed

- An **array** config now points at multi-input (`input: { app: …, cli: … }`)
  rather than just reporting the wrong type, and a **function** config says
  plainly that it is not supported. Both were already refused; neither said what
  to do instead.

### Verified

`defineConfig` was type-checked against a real `tsc` run: a valid config compiles
clean, and a wrong value, a value outside a union, a forbidden `output.format`, an
unknown key and a missing `input` are all caught at edit time — TypeScript even
suggests `minify` for `minfy` on its own.

118 Node tests (+10), 84 Zig tests, 21/21 in the playground judge.

## [0.2.1] — 2026-07-27

### Fixed

- **Two entries could be written to the same file, silently.** Two entries
  resolving to the same name — `["src/a/index.ts", "src/b/index.ts"]`, where both
  are called `index` — or any `output.entryFileNames` without `[name]` made the
  second bundle overwrite the first, while the recap cheerfully reported
  "2 bundles" for the single file on disk.

  Every destination is now computed **before** anything is emitted, and a
  collision is refused with the fix for the case at hand (use the object form of
  `input` to name the entries apart, or add `[name]` to the pattern). The check
  runs **before `clean`**, so a config that cannot produce a coherent result no
  longer destroys the result of the one that could.

  A single entry with a fixed `entryFileNames` stays legitimate and unaffected.

- **`zbundle.config.cjs` is now discovered.** It always *loaded* fine when forced
  with `--config`, but auto-discovery skipped it — so writing one and running
  `zbundle build` reported "no config file found" with the file sitting right
  there. It is the only way to write `module.exports` in a `"type": "module"`
  project, and it types perfectly well with JSDoc:

  ```js
  /** @type {import("zbundle/config").Config} */
  module.exports = { input: "src/index.ts" };
  ```

  It comes last in the lookup order (`.ts`, `.mts`, `.js`, `.mjs`, `.cjs`), and
  the "no config found" message is now derived from that list, so the two cannot
  drift apart.

- **A `.cts` config now says why it cannot work.** Node's type stripping rejects
  `export =`, and `import` is illegal in a CommonJS file, so no `.cts` can import
  `defineConfig`. It stays out of the lookup order deliberately; forcing one with
  `--config` gives an explanation and the two working alternatives instead of
  Node's bare "Cannot use import statement outside a module".

Both found by walking every config key one by one after 0.2.0 shipped. 108 Node
tests (+7), everything else unchanged.

## [0.2.0] — 2026-07-27

**The TypeScript layer**: a config file, a typed `defineConfig`, and a real
`zbundle build`. The rule this layer serves, for the whole package: what is
decided *per module* belongs to Zig, what is decided *per build* belongs to
TypeScript — and this layer ORCHESTRATES, it never computes.

### Added

- **`zbundle/config`** — the public, typed surface: `Config`, `OutputOptions`,
  `ResolveOptions`, and `defineConfig`, the typed identity function.
- **`zbundle build`** — reads `zbundle.config.{ts,mts,js,mjs}` (that lookup order
  is a contract), emits one bundle per entry, writes them under `output.dir`.
  `zbundle build <entry>` bypasses the config entirely. The one-shot form
  (`zbundle <entry>`) is untouched: it is what makes the tool work in a pipe.
- **`resolve.alias`** — exact PREFIX substitution (`'@/' -> './src/'`), applied
  **before** the external test, because `@` and `~` look bare and would otherwise
  never reach the disk. An aliased specifier that does not exist is an ERROR, not
  a silent external. Relative targets resolve against the CONFIG FILE's
  directory, never the cwd.
- **`resolve.extensions`** — the try order becomes configurable; the default is
  the historical table.
- **`minify`** (default: `mode === 'production'`) — shortens cross-module names,
  with the guarantee that a short name never shadows a local or captures a
  global. It is NOT a full minifier: the printer still emits indented, readable
  JS. Compact output needs a compact mode in zcompiler's printer.
- **`output.clean`** — empties the directory first, and refuses to empty the
  working directory or any ancestor of it.
- Multi-input: `string[]` or `Record<name, file>`; a key containing `/`
  (`'cli/index'`) nests the output. The bundles are INDEPENDENT — sharing a
  module means duplicating it, because factoring it out is code splitting.

### Changed

- The Zig resolver takes a `Config { extensions, alias }`, threaded through
  `graph.build` and `linker.Options`. The defaults ARE the previous behaviour, so
  nothing existing changed meaning.
- `bundleWith` accepts `{ minify, resolve }` — a single crossing, at the start of
  the build. By then the TypeScript layer has validated everything and made the
  alias targets absolute.

### The refusals (an option that is accepted must ACT)

`sourcemap: true` (v0.3), `watch: true` (v0.4), `output.chunkFileNames` and
`output.assetFileNames` (v0.5), any `output.format` other than `esm`, and unknown
`entryFileNames` placeholders are errors naming the version they are planned for.
`sourcemap: false` and `watch: false` are accepted — they describe what zbundle
already does. An unknown key is only a warning, with the closest key suggested.

### Verified

84 Zig tests, 101 Node tests, 21/21 in the playground judge — four of those
projects built **through the command**, config file included, so the whole chain
(config -> CLI -> binding -> bundle -> execution -> identical stdout -> importing
witness) is exercised on every run.

## [0.1.1] — 2026-07-26

A **documentation** release. No code changes: the bundler is byte for byte the
one shipped in 0.1.0.

### Added

- **`packages/zbundle/README.md`** — the package README, the one npm renders. It
  was missing, so the npm page was blank while the GitHub-facing root README had
  been there all along. It stands on its own: the command and its flags, the
  full JS API, and above all **how it works** — the resolution table in order,
  breadth-first traversal and cycle detection, scope hoisting (with the
  reference → binding → final name chain, and the table of what materializes and
  what vanishes), and mark & sweep with its explicit purity rule. Plus the four
  refusals and why each one exists.

### Fixed

- **The `@zbundle/binding-*` `optionalDependencies` are no longer declared in the
  committed `package.json`.** Pinning them there meant depending on an artifact
  that only exists **after** publication: pnpm could not resolve it, dropped it
  from the lockfile, and every later `pnpm install --frozen-lockfile` failed with
  `ERR_PNPM_OUTDATED_LOCKFILE`. `zignapi prepublish` now writes them at release
  time — **the published package is identical**, only the versioned manifest
  changed.

## [0.1.0] — 2026-07-26

**The first published release.** A JavaScript/TypeScript bundler written in Zig,
built on [zcompiler](https://github.com/ztoolsmith/zcompiler).

> **A note on numbering** — development went through three internal milestones
> (the graph, the linking, the tree-shaking), tracked in the project journal as
> "v0.1 / v0.2 / v0.3". Since nothing was ever published, those numbers committed
> no one: this first public release therefore starts at **0.1.0**. The milestones
> keep their names in the journal — they are build stages, not npm versions.

### What it does

- **Resolves** relative specifiers: omitted extensions in an order that is a
  contract (`.ts` → `.tsx` → `.js` → `.jsx` → `.mjs`), directory resolution
  (`./utils` → `utils/index.ts`), canonical paths (symlinks, case). **Bare**
  specifiers (`react`, `lodash`) are marked **external** — `node_modules`
  resolution is planned for later.
- **Builds the graph**: every module visited once, cycles detected (iterative
  Tarjan), dynamic `import()` recorded, statistics.
- **Compiles upstream**: TypeScript erased, JSX lowered to `jsx()/jsxs()` — the
  full zcompiler chain, **before** linking (so the `react/jsx-runtime` import
  that the JSX transform injects is visible to the graph).
- **Links by scope hoisting** (rollup's strategy): all modules merged into a
  single scope, collisions resolved by renaming (`name$1`), `import`s vanish
  (they are just name aliases), re-export chains resolve down to the originating
  binding, namespaces are materialized and deduplicated, externals are hoisted
  and merged at the top.
- **Shakes** (tree-shaking, mark & sweep): emit only what is reachable from the
  entry. Roots are every module's top-level side effects plus the entry's
  exports. The purity rule is explicit and **conservative** — when in doubt,
  impure. `/* @__PURE__ */` is honoured.
- **The `zbundle` command**: `-o`, `--format esm|iife`, `--dead`, `--graph`,
  `--watch`, `--quiet`. The bundle goes to stdout, statistics to stderr.

### What it refuses (explicitly, rather than emitting a wrong bundle)

| refusal | why |
|---|---|
| top-level await | would make the whole bundle asynchronous |
| `import.meta` | depends on the module URL, which no longer exists after merging |
| `import()` of an **internal** module | needs a separate chunk → code splitting |
| live binding exposed via a **namespace object** | the object is a snapshot: it would freeze the value |
| `--format iife` with externals | an `import` is illegal inside a function |

A live binding imported **by name** does work: after merging, the importer
references the very same variable.

### Known limitations

- **`node_modules` is not resolved.** Package imports become externals and stay
  in the bundle. This is the most visible limitation: zbundle builds libraries,
  not applications yet.
- No minification, no source maps, no code splitting, no CJS.
- Tree-shaking granularity is the **top-level statement** (no intra-statement
  splitting, no object-property elimination).
- There is no **wasm** backend: a bundler's job is to walk a filesystem, and
  `wasm32-freestanding` does not have one.

### Verified

68 Zig tests, 66 Node tests, **20/20** on the judge (every project is bundled,
**executed**, and must say exactly what the original says; dead code is checked
to be textually absent; exports are checked by an importing witness), 12/12 graph
fixtures, 3/3 real-world projects.

Real world: **lodash-es, 172 modules, 131 → 81 KB in ~30 ms**, output identical
to the original.

Platforms: darwin-arm64, darwin-x64, linux-x64-gnu, linux-x64-musl,
linux-arm64-gnu, win32-x64-msvc.

[0.1.0]: https://github.com/ztoolsmith/zbundle/releases/tag/v0.1.0
