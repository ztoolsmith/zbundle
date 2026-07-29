# zbundle — roadmap

What is delivered, what is refused, and when the refusal is expected to lift.

**The doctrine, which holds at every version:**

- **An option that is accepted ACTS.** A flag that parses without doing anything
  is worse than a missing feature — it lies. Everything not yet built is refused
  with an error naming the version it is planned for.
- **Every version NAMES what it stops refusing**, and removes that refusal in the
  same commit that ships the capability. A message must never outlive what it
  described.
- **A lifted refusal shows up in the judge.** `playground/run.mjs` gains a case
  that exercises it, or it did not really ship.
- **The judge is untouchable**: identical stdout, importing witness, zero
  regression, and two runs producing byte-identical output.

## Delivered

| version | what it brought |
|---|---|
| 0.1.0 | the module graph, scope hoisting, tree-shaking, the CLI |
| 0.2.0 | the TypeScript config layer (`zbundle.config.ts`, `defineConfig`, `zbundle build`), aliases, `minify` |
| 0.2.1–0.2.3 | output collisions, `.cjs` configs, path containment, the CLI obeying its own rule |
| 0.3.0 | `tsconfig.json` — `paths`/`baseUrl` as scoped aliases, `jsx`, `jsxImportSource` |
| **0.4.0** | **source maps** — v3, chained through the whole pipeline, four modes |
| **0.4.1** | **faithful renaming** — the `names` field: a renamed binding resolves to what was written |
| **0.4.2** | **paths** — `sources` relative to the map, POSIX always, `sourceRoot`, `sourcesContent` |

## Refused, with a date

| option | status | planned |
|---|---|---|
| `watch: true` | refused, names v0.5 | v0.5 |
| `output.chunkFileNames` | refused on presence | v0.6 (code splitting) |
| `output.assetFileNames` | refused on presence | v0.6 (asset loaders) |
| `output.format` ≠ `esm` | refused; `iife` exists on the CLI | v0.6 for cjs/umd |
| `[hash]` / `[format]` placeholders | refused | v0.6 |
| `"jsx": "preserve"` | refused — **and always will be** | never |

`"jsx": "preserve"` is the one refusal with no date: zbundle emits JavaScript,
and preserving JSX would mean emitting something another tool still has to
compile.

## Next

- **0.5** — watch mode. The one-shot form already has an interim `--watch`.
- **0.6** — code splitting, and the asset loaders that come with it. The graph
  has carried `is_dynamic` edges since 0.1.0 for exactly this.
- **later** — `node_modules` resolution, intra-statement shaking granularity,
  top-level await.
