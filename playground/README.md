# playground — the laboratory

This is where zbundle is tested by **running it**, not just by reading it.

## `run.mjs` — THE JUDGE

```bash
node run.mjs                 # everything
node run.mjs diamond cycle   # only those projects
node run.mjs --keep          # keep the generated bundles, to read them
```

For each project in `projects/`:

1. run **the original** in Node → reference stdout
2. **bundle** it with zbundle → a single file
3. run **the bundle** in Node → bundle stdout
4. **diff**. Identical = green.

This is the bundler's round-trip — the exact counterpart of zcompiler's
`parse ∘ print`. A bundler that produces code which *runs* but says something
else is a broken bundler; this is the only check that cannot fool itself.

As a free bonus, on every bundle: it **re-parses** with zcompiler without error,
passes semantic analysis with no diagnostics, and **leaks no internal name**
(all its `unresolved` names are known globals).

The judge also verifies the **tree-shaking**, through two optional headers in
`main.*`:

```js
// expect-absent: unused2 unused7 helperOfUnused
// expect-present: keptOne sharedHelper
```

This is essential: identical stdout proves that nothing **live** was removed —
it does not prove that the **dead** was.

### The importing witness

Running a bundle as a script **ignores its `export`s**. So a project that
declares exports makes the harness generate a module that **imports the bundle**
and checks its contract:

```js
// expect-exports: jamaisUtilisee:function ns:object
// expect-call: jamaisUtilisee(42) -> inutile 42
```

`Object.keys` plus `typeof` for every name, then an **actual call** of the ones
an `expect-call` designates (arguments in JSON). Exports are a contract; they get
tested as one — not as a side effect.

Then `refusals/`: every documented limitation **must** produce an error, and one
that explains itself (≥ 2 lines). A silently wrong bundle would be worse than a
refusal.

## `inspect.mjs` — the eye

```bash
node inspect.mjs                  # list the projects
node inspect.mjs barrel           # the whole bundle
node inspect.mjs barrel --graph   # + the module graph
node inspect.mjs barrel --run     # + execution
node inspect.mjs barrel --dead    # + what shaking removed (module, line, reason)
node inspect.mjs ../some/main.js  # any entry
```

To **understand what the linker did**: see the renamed collisions (`helper`,
`helper$1`, `helper$2`), the materialized namespaces, the modules that emit
nothing (a pure barrel), the topological order. The counterpart of zcompiler's
debug printer, which showed the AST.

## Adding a case — 30 seconds

```bash
mkdir projects/my-case
$EDITOR projects/my-case/main.js     # plus the modules it imports
node run.mjs my-case
```

**The only rule**: `main.*` must `console.log` a **deterministic** result (no
clock, no randomness, no fragile `Set`/`Map` ordering). The judge compares two
stdouts: anything that varies between runs makes it fail for the wrong reason.

For a case that must **fail**:

```bash
mkdir refusals/my-refusal
echo '// expect-error: what zbundle must refuse' > refusals/my-refusal/main.js
```

## The projects

| project | what it traps |
|---|---|
| `diamond` | the shared module is evaluated **exactly once** (a counter proves it) |
| `cycle` | two mutually recursive functions, across an import cycle |
| `barrel` | chained re-exports, `export * as ns`, `export *`, and **three** colliding `helper`s |
| `ts-jsx` | the full zcompiler chain: types erased and JSX lowered, **before** linking |
| `external` | real `node:fs`/`node:path`, imported by two modules → a single import |
| `default-heavy` | the three forms of `export default` (anonymous expression, class, binding) |
| `live-binding` | a reassigned `export let`: hoisting handles it **naturally** |
| `real-lodash` | the real world — **172 modules** of lodash-es, results verified |
| `shake-barrel` | **the textbook case**: 1 function imported out of 20 → 24 modules become 3 |
| `shake-sideeffect` | a module patching a global: imported for its effect, it **survives** |
| `shake-diamond` | a half-dead diamond: the shared part lives, the dead branch falls |
| `shake-class` | a pure never-instantiated class (removed) vs an impure static field (kept) |
| `shake-star` | `export *` partially consumed |
| `shake-getter` | the trap: `obj.prop` may be a getter, so it is kept |
| `export-unused` | the edge case: **exported + zero references** survives, its private twin dies |
| `export-forms` | the **7 export forms**, all called through the imported bundle |

| refusal | the limitation |
|---|---|
| `top-level-await` | would make the whole bundle asynchronous |
| `import-meta` | depends on the module URL, which no longer exists after merging |
| `dynamic-internal` | an internal `import()` = a separate chunk → code splitting |
| `namespace-live` | the namespace object is a **snapshot**: it would freeze a live binding |

## Also here

- `index.js` — shows the **graph** of an entry.
- `corpus.js` — the harness for `corpus/fixtures/` (`--graph`) and the real-world
  projects (`--real`). Strict comparison against an `expected.json`.
