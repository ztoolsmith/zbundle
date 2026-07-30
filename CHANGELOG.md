# Changelog

All notable changes to zbundle. Format inspired by
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[SemVer](https://semver.org/).

## [0.4.4] — 2026-07-29

**Codeframes.** An error that says what went wrong now also says where.

```
✘ cannot resolve './accentué.ts'
    tried:
      /project/src/accentué.ts
    src/main.ts:2:22
    2 │ import { café } from './accentué.ts';
      │                      ^
```

**This is presentation, not a refusal being lifted.** The same builds fail for the
same reasons; they just stop making you find the line yourself. Almost free by
now: the byte-exact spans have been on every node since day one, and 0.4.0 built
the machinery that turns a byte offset into a line and a column.

### Added

- **`native/codeframe.zig`** — `file:line:column`, the offending line, a caret
  under the column. Columns count **UTF-16 code units**, so the caret lands where
  an editor puts its cursor even on a line holding an accent or an emoji. A tab is
  rendered as one space: keeping it would place the caret wherever the terminal's
  tab width decides.
- **`src/codeframe.ts`** — the same shape for the build's OWN files, which never
  reach the addon: a malformed `tsconfig.json` now shows the character that broke
  it. Symmetry rather than sharing — copying a whole source across the N-API
  boundary to have a caret drawn there would be a lot of work to avoid twenty
  lines.

### Which errors point, and which cannot

| error | points at |
|---|---|
| resolution failure | the **import that asked** — not merely the file |
| internal `import()` | the `import(…)` call |
| live binding via a namespace | the `export let` that gets reassigned |
| malformed `tsconfig.json` | the offending character |
| top-level await, `import.meta` | **the file only** |

The last two are honest about it: zcompiler reports them as **booleans**, with no
offset. Inventing one would point at a character that means nothing, so they
carry the file and no frame — and that stays true until the compiler exposes a
position. Adding the header that demands a frame to one of those projects makes
the judge fail, which is how it is kept honest.

Config *value* errors (`sourcemap: "linked"`) have no frame either, and cannot:
the config was evaluated by Node, so there is no offset for a key.

### Details

- The dynamic-import refusal re-derives its offset from the module records rather
  than carrying it on the graph edge. `Edge` is part of the JS-facing shape and of
  the corpus contract; widening it for a message would be a poor trade.
- `codeframe.render` frees its intermediate buffers. Production passes it the call
  arena, which would swallow them — but depending on the caller's allocator being
  an arena is a promise the file cannot check, and the leak showed up under the
  test allocator.

### Judge

**31/31**, with a new `expect-codeframe` header on the two refusals that can
point. Negative-controlled twice: a wrong expectation fails, and demanding a frame
from a refusal that has no position fails too.

180 Node tests (+8), 106 Zig tests (+6), 12/12 fixtures, 3/3 real-world projects.
One pre-existing assertion was updated rather than the code reverted: it required
`from <importer>`, which the codeframe now states more precisely as
`<importer>:line:column`.

## [0.4.3] — 2026-07-29

**Minify and source maps together.** Everything the bundle emits now has a
position — including the two things the linker writes itself.

### Fixed

- **Two synthesized constructs carried no mapping at all.** The
  `const <name> =` that binds an `export default <expression>`, and the
  materialized namespace object (`const x_ns = { … }`), are written by the LINKER
  rather than printed from any node — so nothing mapped them.

  Harmless-looking while names stayed readable, a dead end once `minify` turned
  them into `b` and `ns_ns`: clicking either in a debugger led nowhere. They now
  point at what they stand for — the `export default` statement for the former,
  the start of the module for the latter, since a namespace object stands for the
  whole module and not for one line of it.

  Every line of real code in a minified bundle maps, and that is now asserted as
  a whole rather than case by case.

### Details

- `minify` and `sourcemap` are **orthogonal**: asking for a map does not change
  one byte of the code, and `minify` alone still emits no map. Pinned by a test
  comparing the two outputs.
- A mangled name resolving to its original was already delivered in 0.4.1. What
  this release adds is the guarantee that *nothing is left out* — the previous
  checks looked at identifiers, not at every emitted line.

### Not in this release

- **The compact printer does not exist.** The brief anticipated a single-line,
  dense-column output arriving in zcompiler in parallel; it is not there — no
  trace of it in `printer.zig` or anywhere else in the compiler. So there is no
  compact output to keep a map correct on, and nothing was written against a
  capability that does not exist. Whenever it lands, the column mapping it needs
  is the part already exercised here.

### Judge

**31/31** (+1). `sourcemap-minify` builds with `minify: true` and
`sourcemap: true`, and pairs the name check with an `expect-absent` on the
readable name — so the name assertion cannot pass by accident on an unminified
bundle. Both halves were negative-controlled.

173 Node tests (+5), 100 Zig tests, 12/12 fixtures, 3/3 real-world projects.

## [0.4.2] — 2026-07-29

**Paths.** Where `sources` points, and what a consumer is told about it.

### Added

- **The long form of `sourcemap`**, for the two things a mode alone cannot say:

  ```ts
  sourcemap: { mode: "hidden", sourceRoot: "/@src/", sourcesContent: false }
  ```

  Writing the object at all means you want a map, so `mode` defaults to `true`.
  The short form (`true` / `'inline'` / `'hidden'` / `false`) is unchanged.

- **`sourceRoot`** — emitted only when asked. Absent is not the same as empty,
  and some consumers treat the two differently.

- **`sourcesContent: false`** — promised when 0.4.0 shipped and left undone. It
  makes a much smaller map, for setups that serve the sources themselves.

### Details

- **`sources` are relative to the MAP, whatever `output.dir` is.** A nested
  `output.dir` gains the matching `../..`; resolving against the cwd instead
  would leave the entries unchanged and point at nothing — the map still parses,
  the debugger just opens the wrong file. That is now pinned at two depths.
- **Always forward slashes.** A `\` in a `sources` entry reads as an escape, not
  a directory: a bundle built on Windows has to open on Linux.
- **`file://` when no relative path exists.** On Windows a source on another
  drive cannot be reached relatively at all — `path.relative` hands back an
  absolute path, which is not a valid `sources` entry. An absolute URL is the
  honest answer. `sourceEntry` takes its path primitives as arguments so this is
  exercised from any platform, rather than hoping the Windows CI job covers it.

### Fixed

- The map was **assembled twice** per bundle — once for the inline data URL and
  once for the file. Wasted work, and two chances to pass different options.
- The judge looked for the bundle and the map at the top of `dist/` only, so a
  nested `output.dir` was invisible to it. Both lookups are now recursive.
- The judge read `sourcesContent` by indexing `map.sources`, which finds nothing
  once a `sourceRoot` is set — the consumer hands back the PREFIXED path. It now
  asks the library through `sourceContentFor`.

### Judge

**30/30** (+1). `sourcemap-outdir` builds into `dist/build/js` with a
`sourceRoot`, and the judge resolves an identifier back through the map to check
the line it lands on really contains it — which is what makes a wrong depth
visible.

168 Node tests (+7), 100 Zig tests, 12/12 fixtures, 3/3 real-world projects.

## [0.4.1] — 2026-07-29

**Faithful renaming.** A renamed binding now hands a debugger the name that was
actually written, not the one the bundler invented.

### Added

- **The `names` field.** 0.4.0 left it empty and said so; this fills it. A
  minified bundle saying `a` now resolves to `helperWithLongName`, at the
  declaration **and** at every reference.
- A name is recorded exactly when the emitted identifier DIFFERS from the source
  one. An unchanged identifier gets none: the debugger reads the source, and a
  name would be dead weight in every build that does not minify.
- **In zcompiler (0.4.1)**: `Mapping.name` says whether what is marked is an
  identifier — the only thing that can be renamed, so the only thing worth
  naming.

### Details

- **The "original name" is per POSITION**: the identifier as written *at that
  source offset*. An aliased import (`import { shared as x }`) therefore carries
  `x` on its references inside the importing file — that is what the developer
  typed there, and what they should be shown. The exporter's own name appears on
  the declaration, in its own file.
- Positions were already faithful in 0.4.0 — renaming replaces a node's text,
  never its span — and the hoisted prelude never shifted anything, because the
  printer writes into the bundle's own buffer. Both had tests; this release adds
  the missing half, the NAME.

### Fixed

- **The judge's source-map check never ran.** `SourceMapConsumer.with` returns a
  promise, and the check read its results synchronously — so `problems` was
  always empty and every project passed. It was inert from the moment it was
  added in 0.4.0. Found by a negative control: sabotage an expectation, and a
  green result is the bug. The check is now awaited, and it immediately caught
  two wrong expectations of my own.
- Lines the LINKER synthesizes — the hoisted `import` prelude and the final
  `export { … }` — are excluded from the "everything maps" sweep. No character
  of any source produced them.

### Judge

**29/29** (+2). `sourcemap-renamed` (one renamed identifier, three occurrences,
each leading back to the `shared` written in its own module) and
`sourcemap-externals` (a hoisted prelude above every module body, with the
mapping under it verified). A new `expect-sourcemap-name` header checks EVERY
occurrence, not just the first.

100 Zig tests (+1, in zcompiler), 161 Node tests (+4).

## [0.4.0] — 2026-07-28

**Source maps.** A position in the bundle points back at the exact character of
the original `.ts` — through type stripping, JSX lowering, scope hoisting and
cross-module renaming.

### Added

- **`sourcemap: false | true | 'inline' | 'hidden'`**, and `--sourcemap[=mode]`
  on the command line (CLI wins over the config). `true` writes a `.js.map` and
  the `sourceMappingURL` comment; `inline` embeds a base64 data URL; `hidden`
  writes the map and says nothing, for setups that upload it out of band;
  `false` is the default and costs **not one byte**.
- `sourcesContent` is embedded, so debugging needs no access to the source tree.
- **In zcompiler**: the printer can now emit a stream of `(output offset ->
  source offset)` alongside the text. Three `*With` variants; the historical
  functions delegate with an empty sink and stay byte-identical.

### Lifts

- **`sourcemap` is no longer a reserved option.** The refusal was removed in the
  same change that delivered the feature, and the judge gained the cases that
  exercise it.

### Details

- **Renaming does not move a position.** A binding renamed by the linker
  (`shared$1`) keeps its NODE — only the text changes — so the mapping still
  points at the identifier that was written. That falls out of the design rather
  than being arranged.
- **Synthetic nodes are not mapped.** The `import` that the JSX transform
  injects, an `enum` IIFE: nothing in the source produced them, and pointing at
  byte 0 would be worse than pointing nowhere. Omitting the segment is also the
  right answer — a segment holds until the next one, so synthetic output is
  attributed to the enclosing statement. A folded literal is the exception: the
  transformer gives it the span of the expression it replaced, so `7` maps back
  to `1 + 2 * 3`.
- **Bytes are not columns.** Zig counts bytes, a source map counts UTF-16 code
  units, and the bundle banner alone (`—`, `──`) drifts ten units before the
  first statement. Every conversion decodes the UTF-8 instead of assuming.
- `names` is empty: it is what shows a debugger the ORIGINAL name of a renamed
  binding, and that is its own chantier.

### Judge

`playground/run.mjs` **27/27** (+2), with a new `expect-sourcemap` check that
decodes the map with the standard `source-map` consumer, walks every line of
real code, and verifies one named position against the actual source text.
Projects: `sourcemap-basic` (three modules merged) and `sourcemap-jsx` (the full
chain through JSX lowering).

99 Zig tests (+6, in zcompiler), 157 Node tests (+11), 12/12 fixtures, 3/3
real-world projects. `sourcemap: false` is byte-identical to the previous
release, and two runs produce identical maps.

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

- **The alias scope is canonical.** `resolver.zig` compares it against module
  directories that went through `realPath`, so a scope built from a path that was
  never canonicalised — `/var` vs `/private/var` on macOS, any symlinked checkout
  — would never match and the tsconfig would silently do nothing.

- **A malformed `paths` entry is reported.** Mapping a key to a string instead of
  an array, to an empty array, or to non-strings used to be skipped without a
  word; the only symptom was a "cannot resolve" further down with nothing
  pointing back at it. Validating a tsconfig stays `tsc`'s job, so the build goes
  on — but it says what it ignored.

### Verified

93 Zig tests (+9), 146 Node tests (+20), **25/25** in the playground judge — four
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
