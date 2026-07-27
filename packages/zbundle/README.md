# zbundle

A JavaScript/TypeScript bundler written in **Zig**, built on
[zcompiler](https://www.npmjs.com/package/zcompiler) (the compiler) and exposed to
Node.js through [zignapi](https://www.npmjs.com/package/zignapi).

`zbundle.bundle(entry)` returns a **single executable JS file** (ESM) containing
**only the code reachable from the entry**.

```sh
npm install zbundle          # the library and the `zbundle` command
```

> Importing 1 function out of a 20-function barrel:
> **24 modules / 4022 B → 3 modules / 260 B**.

## The command

```sh
zbundle src/index.tsx -o dist/bundle.js
```
```
✔ dist/bundle.js  3 modules  0 externals  −80 statements, −21 modules
  4022 → 260 bytes (6 %) in 2.5 ms  esm
```

Two shapes, and both are first-class. **The project shape** reads a config file
and may emit several bundles:

```
zbundle build                    build from zbundle.config.ts
zbundle build <entry>            build one entry, ignoring any config
  -c, --config <file>            config file (.ts, .mts, .js, .mjs)
      --out-dir <dir>            override output.dir
      --minify                   override minify
```

**The one-shot shape** takes no config, emits one bundle, and writes to stdout by
default — which is what makes it usable in a pipe:

```
zbundle <entry> [-o <file>]      bundle (statistics go to stderr)
  -f, --format esm|iife          iife: everything in an IIFE, needs zero externals
      --dead                     list what tree-shaking removed
      --graph                    the module graph, without bundling
      --watch                    rebuild on change (requires -o)
      --quiet                    no statistics
```

**Statistics go to stderr, never to stdout**: `zbundle x.js > out.js` gives you a
clean file *and* readable numbers on screen. A refusal exits with **code 1**, its
explanation intact, and writes **nothing** to stdout — a pipe never receives
invalid JS.

## The config

```ts
// zbundle.config.ts
import { defineConfig } from "zbundle/config";

export default defineConfig({
  mode: "production",                       // its ONLY effect: minify defaults to true
  input: { main: "src/index.ts", "cli/index": "src/cli.ts" },
  output: { dir: "dist", clean: true },     // a key with a slash nests the output
  resolve: { alias: { "@/": "./src/" } },   // relative to THIS FILE, not the cwd
});
```

| key | default | notes |
|---|---|---|
| `mode` | `'development'` | its ONLY v1 effect is the `minify` default |
| `input` | *required* | `string`, `string[]`, or `Record<name, file>` |
| `output.dir` | `'dist'` | |
| `output.format` | `'esm'` | the only format; `iife` lives on the CLI |
| `output.entryFileNames` | `'[name].js'` | `[name]` is the only placeholder |
| `output.clean` | `false` | refuses to empty the cwd or any ancestor |
| `resolve.alias` | `{}` | exact PREFIX substitution, applied before the external test |
| `resolve.extensions` | `['.ts','.tsx','.js','.jsx','.mjs']` | order is meaning |
| `minify` | `mode === 'production'` | shortens cross-module names |

Lookup order: `zbundle.config.ts` → `.mts` → `.js` → `.mjs`, or `--config`.
TypeScript loads through Node's own type stripping (22.6+), so nothing extra is
installed; jiti is used as a fallback when the project already has it.

**Command line > config file > defaults.**

### What it refuses, and why

> An option that is accepted must ACT.

`sourcemap: true` (v0.3), `watch: true` (v0.4), `output.chunkFileNames` and
`output.assetFileNames` (v0.5), an `output.format` other than `esm`, and an
unknown `entryFileNames` placeholder are **errors** that name the version they
are planned for. Accepting one of them and quietly doing nothing would be the
worst of the possible behaviours. Setting `sourcemap: false` or `watch: false` is
fine — that is what zbundle does today.

An unknown key is only a **warning**, with the closest match suggested, and the
build carries on: a typo should not stop your work.

## The API

```js
import zbundle from "zbundle";

zbundle.bundle("src/index.tsx");        // -> a JS string
zbundle.bundleStats("src/index.tsx");   // -> { code, stats }
zbundle.bundleReport("src/index.tsx");  // -> { code, stats, dead: [{ module, line, snippet, reason }] }
zbundle.bundleWith("src/index.tsx", { format: "iife", dead: true });

zbundle.graph("src/index.tsx");         // -> { modules, edges, externals, cycles, stats }
zbundle.graphPrint("src/index.tsx");    // -> the graph as a readable tree
zbundle.resolve(fromDir, "./utils");    // -> { kind: "file" | "external", path }
```

## How it works

### 1. Resolve

`resolve(fromDir, specifier)`, in this exact order:

| # | Case | Behaviour |
|---|---|---|
| 1 | **bare** specifier (`react`, `@scope/pkg`, `node:fs`) | → **external**, stop. **Never an error.** |
| 2 | path with a **known extension** (`./a.ts`) | tried **as-is**, and nothing else |
| 3 | extension **omitted** (`./a`) | `a.ts` → `a.tsx` → `a.js` → `a.jsx` → `a.mjs` |
| 4 | still nothing, no known extension | `a/index.ts` → `.tsx` → `.js` → `.jsx` → `.mjs` |
| 5 | still nothing | **error**: the specifier, the requesting file, and **every** path tried, in order |

`.ts` before `.js` is a tested contract: a TypeScript project that compiled an
`x.js` next to its `x.ts` must see the **source**, not the output.

The returned path is **canonical** — symlinks followed, case corrected on a
case-insensitive filesystem — and that path, alone, is the deduplication key. Two
different routes to the same file yield **one** module.

### 2. Traverse

Breadth-first from the entry. Each module is read and parsed **once**, gets an id
at discovery time, and its zcompiler module records become edges. TypeScript is
erased and JSX is lowered to plain JS **before** the records are extracted — that
matters, because the JSX transform *injects* `import { jsx } from
'react/jsx-runtime'`, and doing it afterwards would hide that dependency from the
graph.

**Cycles are not an error** — ESM cycles are legal and real code has them. They
are detected with **iterative Tarjan** (a cycle = a strongly connected component
of size > 1, or a self-import) so the list is complete, duplicate-free, and never
combinatorial. Iterative, not recursive: real projects have chains hundreds of
modules deep.

### 3. Link — scope hoisting

> **Every module is concatenated into ONE scope, and name collisions are resolved
> by renaming.**

This is rollup's strategy. No function wrappers, no runtime module registry: the
output is **flat, readable JS** that engines optimize like hand-written code.

The trick is that there is **nothing to rewrite inside module bodies**. zcompiler
already knows, for each module, its top-level bindings and *every* reference to
them. Setting `new_name` on a binding updates all of its references at once, so an
`import` becomes literally a **name alias** and disappears from the output:

```
reference to `a` in m.js
  → local binding `a` of m (kind = .import_)
    → ImportEntry { specifier: './x', imported: 'a' }
      → module x, ExportEntry { exported: 'a', … }
        → (.local)      x's local binding  → its FINAL NAME
        → (.re_export)  start again at x's source
        → (.star_as)    the materialized namespace object
```

Emission order is a post-order DFS from the entry: a module is emitted after all
its dependencies. Names are then assigned in that order — a binding keeps its own
name when it is free, otherwise it becomes `name$1`, `name$2`. Keywords **and
every unresolved global of every module** are reserved up front, so a local is
never renamed into `console`. A name that does not collide is **never** touched:
the bundle stays readable and debuggable.

| construct | in the bundle |
|---|---|
| `import { a } from './x'` | **nothing** — `a` is renamed to x's final name |
| `export const x = 1` | `const x = 1` (the keyword drops) |
| `export { a } from './x'` | **nothing** — an alias, resolved in the table |
| `export * from './x'` | **nothing** — names resolve straight through |
| `export * as ns from './x'` | `const x_ns = { … }` — **the only materialization** |
| `import * as ns from './x'` | same, and **deduplicated** with the above |
| `export default <expr>` | `const <module>_default = <expr>` |
| the **entry's** exports | a final `export { … }`: the only survivors |
| `import x from 'react'` | hoisted to the top, **merged** across modules |

### 4. Shake — mark & sweep

Emit only what is **reachable from the entry**, with one rule that settles every
doubtful case:

> **When in doubt: IMPURE.**

A bundle 5 % larger is one bug fewer. A statement wrongly judged pure disappears,
and with it a side effect the program expected — the kind of bug you only find in
production.

| PURE (removable) | IMPURE (a root) |
|---|---|
| `function f() {…}`, `class C {…}` | any call: `f()`, `new X()`, an IIFE, a tagged template |
| `const x = <literal \| function \| arrow \| pure class \| identifier>` | any mutation: `x.y = …`, `x++`, `delete o.p` |
| a template whose expressions are all pure | **any member access** `obj.prop` — it might be a **getter** |
| `import`, `export` declarations | `if`, `for`, `throw`, `await` — anything that executes |
| `class A extends Base` | `class A extends getBase()` |
| `class A { static x = 1 }` | `class A { static x = compute() }` |
| `/* @__PURE__ */ f()` (the author's promise) | `f()` without the annotation |

Member access is impure although it looks harmless: `obj.prop` can fire an
arbitrary getter, so it is a call in disguise.

**The roots** are exactly two families: every impure top-level statement of every
module in the graph (a module in the graph *will* be evaluated, which is what
makes `import './polyfill'` work), and the entry's exports. Propagation runs to a
fixed point through an explicit worklist — a live unit keeps alive the bindings it
uses, and each live binding keeps alive the unit declaring it.

Import and re-export chains are **traversed**: importing `a` from `x` marks only
`x`'s binding `a`, not all of `x`. That is the whole win on barrels. `import * as
ns`, on the other hand, marks **everything** — a namespace object exposes all of
it, and there is no way to know what will be read. That is the price of a
namespace, and a reason to import by name.

Granularity is the **top-level statement**: a declaration lives or dies whole.
And a dead binding **does not consume a name** — otherwise an eliminated `helper`
would push a live `helper` from another module to `helper$1`, for nothing.

## What it refuses, and why

Each refusal is verified by a dedicated project and carries a message saying what
to do. A silently wrong bundle would be worse.

| refusal | why |
|---|---|
| top-level await | would make the whole bundle asynchronous |
| `import.meta` | depends on the module URL, which no longer exists after merging |
| `import()` of an **internal** module | needs a separate chunk → code splitting |
| live binding exposed via a **namespace object** | the object is a snapshot: it would freeze the value |

A live binding imported **by name** (a reassigned `export let`) works fine: after
merging, the importer references the very same variable. Only the namespace object
breaks, so the refusal points exactly there and nowhere else.

**`node_modules` is not resolved yet** — package imports become externals and stay
in the bundle. zbundle builds libraries, not applications, for now.

## Status

| | |
|---|---|
| Zig tests | 84 |
| Node tests | 101 |
| the judge (the bundle runs and says what the original says) | **21/21** |
| graph fixtures | 12/12 |
| real-world projects | 3/3 |
| real world | **lodash-es: 172 modules, 131 → 81 KB, 30 ms**, identical output |

## Requirements

- **Node ≥ 18** to consume the npm package (the binary for your platform is
  installed automatically via `@zbundle/binding-<triple>`).
- **Zig 0.16.0** and **zcompiler ≥ 0.3.0** to build from source.

MIT.
