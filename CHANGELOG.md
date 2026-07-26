# Changelog

All notable changes to zbundle. Format inspired by
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[SemVer](https://semver.org/).

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
