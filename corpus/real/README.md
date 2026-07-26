# corpus/real — the real-world projects

The fixtures (`../fixtures/`) are handmade: each tests ONE aspect, with an exact
`expected.json`. Here it is the opposite — **real code**, that we did not write,
where we only check what is checkable without an oracle:

- the graph **builds** (no crash, no infinite loop);
- the statistics are **plausible** (module, edge and cycle counts);
- zero parse errors (otherwise the gap is zcompiler's, not zbundle's).

`node_modules/` is **gitignored** (the same convention as zcompiler's `corpus/`).
To populate it:

```bash
cd corpus/real && npm install
```

`lodash-es` is the centrepiece: ~640 ESM modules, all relative imports with
explicit extensions, and a `lodash.js` that re-exports the whole package — a
graph both wide and deep, exactly what a bundler has to swallow.
