// Node tests (`node --test`) through the addon: the real JS surface, the one a
// user sees. The Zig tests (`zig build test`) cover the inside; here we check
// the N-API boundary crossing and the mandatory cases.
//
// The `corpus/fixtures/` fixtures double as data: a single source of truth
// between the corpus harness and these tests.
const test = require("node:test");
const assert = require("node:assert");
const path = require("node:path");
const fs = require("node:fs");
const zbundle = require("./index.js");

const FIXTURES = path.join(__dirname, "..", "..", "corpus", "fixtures");
const REAL = path.join(__dirname, "..", "..", "corpus", "real");
const fixture = (name, file) => path.join(FIXTURES, name, file);

/** The module paths, relative to the fixture, sorted. */
const modulesOf = (g, root) =>
  g.modules.map((m) => path.relative(root, m.path).split(path.sep).join("/")).sort();

/** The module for an id, relative. */
const at = (g, root, id) => path.relative(root, g.modules[id].path).split(path.sep).join("/");

// ---- the resolver alone ----

test("resolver: the extension table, case by case", () => {
  const dir = path.join(FIXTURES, "omitted-ext");
  // Each `pick-*` has TWO candidate files; the order .ts > .tsx > .js > .jsx > .mjs decides.
  const cases = [
    ["./pick-ts", "pick-ts.ts"], // .ts gagne sur .js
    ["./pick-tsx", "pick-tsx.tsx"], // .tsx gagne sur .js
    ["./pick-js", "pick-js.js"], // .js gagne sur .jsx
    ["./pick-jsx", "pick-jsx.jsx"], // .jsx gagne sur .mjs
    ["./pick-mjs", "pick-mjs.mjs"], // seul candidat
  ];
  for (const [specifier, want] of cases) {
    const r = zbundle.resolve(dir, specifier);
    assert.equal(r.kind, "file");
    assert.equal(path.basename(r.path), want, `${specifier} must resolve ${want}`);
  }
});

test("resolver: './x' resolves x.ts BEFORE x.js", () => {
  const dir = path.join(FIXTURES, "omitted-ext");
  // The negative control: both files really do exist.
  assert.ok(fs.existsSync(path.join(dir, "pick-ts.ts")));
  assert.ok(fs.existsSync(path.join(dir, "pick-ts.js")));
  assert.equal(path.basename(zbundle.resolve(dir, "./pick-ts").path), "pick-ts.ts");
});

test("resolver: './dir' -> dir/index.ts (and index.ts wins over index.js)", () => {
  const dir = path.join(FIXTURES, "index-resolution");
  assert.equal(zbundle.resolve(dir, "./utils").path.endsWith(path.join("utils", "index.ts")), true);
  // widgets/ has index.js AND index.ts: the source must win.
  assert.equal(zbundle.resolve(dir, "./widgets").path.endsWith(path.join("widgets", "index.ts")), true);
});

test("resolver: an explicit extension is taken as is", () => {
  const dir = path.join(FIXTURES, "omitted-ext");
  assert.equal(path.basename(zbundle.resolve(dir, "./pick-ts.js").path), "pick-ts.js");
});

test("resolver: bare specifier -> external, never an error", () => {
  const dir = path.join(FIXTURES, "externals");
  for (const spec of ["react", "@scope/ui", "lodash/debounce", "node:fs/promises"]) {
    const r = zbundle.resolve(dir, spec);
    assert.equal(r.kind, "external");
    assert.equal(r.path, spec);
  }
});

test("resolver: canonical path ('..' does not open two modules)", () => {
  const dir = path.join(FIXTURES, "chain");
  const direct = zbundle.resolve(dir, "./b.js").path;
  const detour = zbundle.resolve(dir, "./../chain/./b.js").path;
  assert.equal(direct, detour);
  assert.ok(path.isAbsolute(direct));
});

test("resolver: not found -> error with the attempted paths", () => {
  const dir = path.join(FIXTURES, "chain");
  assert.throws(
    () => zbundle.resolve(dir, "./missing"),
    (err) => {
      assert.match(err.message, /cannot resolve '\.\/missing'/);
      assert.match(err.message, /tried:/);
      // The 5 extensions THEN the 5 index.<ext>, in table order.
      assert.match(err.message, /missing\.ts/);
      assert.match(err.message, /missing\.tsx/);
      assert.match(err.message, /missing\.js/);
      assert.match(err.message, /missing\.jsx/);
      assert.match(err.message, /missing\.mjs/);
      assert.match(err.message, /missing[/\\]index\.ts/);
      assert.ok(err.message.indexOf("missing.ts") < err.message.indexOf("missing.js"));
      return true;
    },
  );
});

// ---- the graph ----

test("graph: simple chain a -> b -> c", () => {
  const root = path.join(FIXTURES, "chain");
  const g = zbundle.graph(fixture("chain", "entry.js"));
  assert.deepEqual(modulesOf(g, root), ["b.js", "c.js", "entry.js"]);
  assert.equal(g.stats.edges, 2);
  assert.equal(at(g, root, g.entry), "entry.js");
});

test("graph: the diamond yields 4 modules, not 5 (deduplication)", () => {
  const root = path.join(FIXTURES, "diamond");
  const g = zbundle.graph(fixture("diamond", "entry.js"));
  assert.equal(g.stats.modules, 4);
  assert.equal(g.stats.edges, 4); // BOTH edges to d exist
  const d = g.modules.find((m) => m.path.endsWith("d.js")).id;
  assert.equal(g.edges.filter((e) => e.to === d).length, 2);
  assert.equal(g.stats.cycles, 0);
});

test("graph: the cycle is detected, listed, and is NOT an error", () => {
  const root = path.join(FIXTURES, "cycle");
  const g = zbundle.graph(fixture("cycle", "entry.js")); // ne throw pas
  assert.equal(g.stats.modules, 2);
  assert.equal(g.stats.cycles, 1);
  assert.deepEqual(
    g.cycles[0].map((id) => at(g, root, id)).sort(),
    ["b.js", "entry.js"],
  );
});

test("graph: a cycle does not loop (the run terminates)", () => {
  // The real infinite-loop test: this test returns.
  const g = zbundle.graph(fixture("cycle", "entry.js"));
  assert.ok(g.stats.build_ms >= 0);
});

test("graph: 'react' becomes external and the graph CARRIES ON", () => {
  const root = path.join(FIXTURES, "externals");
  const g = zbundle.graph(fixture("externals", "entry.js"));
  assert.deepEqual(modulesOf(g, root), ["entry.js", "local.js"]); // the graph carried on
  assert.equal(g.stats.externals, 5);
  const react = g.externals.find((e) => e.specifier === "react");
  assert.equal(react.count, 2); // deduplicated, but counted twice
  const edge = g.edges.find((e) => e.specifier === "react");
  assert.equal(edge.to, null);
  assert.equal(g.externals[edge.external].specifier, "react");
});

test("graph: './missing' -> error with the importer and the attempted paths", () => {
  const dir = path.join(FIXTURES, "chain");
  const entry = path.join(dir, "broken-entry.js");
  fs.writeFileSync(entry, "import './b.js';\nimport './missing';\n");
  try {
    assert.throws(
      () => zbundle.graph(entry),
      (err) => {
        assert.match(err.message, /cannot resolve '\.\/missing'/);
        assert.match(err.message, /from .*broken-entry\.js/); // the importer
        assert.match(err.message, /tried:/);
        assert.match(err.message, /missing\.ts/);
        return true;
      },
    );
  } finally {
    fs.unlinkSync(entry);
  }
});

test("graph: a .tsx entry (JSX + types) parses and its imports come out", () => {
  const root = path.join(FIXTURES, "mixed-ext");
  const g = zbundle.graph(fixture("mixed-ext", "entry.tsx"));
  assert.equal(g.stats.parse_errors, 0); // JSX and types broke nothing
  assert.equal(g.modules[g.entry].format, "tsx");
  assert.deepEqual(modulesOf(g, root), ["data.ts", "entry.tsx", "format.js", "row.jsx"]);
  // Each file was parsed in ITS OWN mode.
  const fmt = Object.fromEntries(g.modules.map((m) => [path.basename(m.path), m.format]));
  assert.deepEqual(fmt, {
    "entry.tsx": "tsx",
    "row.jsx": "jsx",
    "data.ts": "ts",
    "format.js": "js",
  });
});

test("graph: `export { a } from './b'` IS a dependency", () => {
  const root = path.join(FIXTURES, "re-exports");
  const g = zbundle.graph(fixture("re-exports", "entry.js"));
  const edge = g.edges.find((e) => e.specifier === "./y.js");
  assert.ok(edge, "the re-export edge must exist");
  assert.equal(edge.kind, "re_export");
  assert.equal(at(g, root, edge.to), "y.js");
});

test("graph: `export * from` is a dependency, transitively", () => {
  const root = path.join(FIXTURES, "export-star");
  const g = zbundle.graph(fixture("export-star", "entry.js"));
  assert.deepEqual(modulesOf(g, root), ["a.js", "b.js", "deep.js", "entry.js"]);
  assert.equal(g.edges.find((e) => e.specifier === "./a.js").kind, "export_all");
});

test("graph: import() is followed AND marked is_dynamic", () => {
  const g = zbundle.graph(fixture("dynamic-import", "entry.js"));
  const lazy = g.edges.find((e) => e.specifier === "./lazy.js");
  assert.equal(lazy.kind, "dynamic_import");
  assert.equal(lazy.is_dynamic, true);
  // A static import stays non-dynamic.
  assert.equal(g.edges.find((e) => e.specifier === "./eager.js").is_dynamic, false);
  // `import(variable)` is not analysable: no edge, no error.
  assert.equal(g.edges.length, 6);
});

test("graph: `import type` is NOT an edge (erased on emission)", () => {
  const dir = path.join(FIXTURES, "chain");
  const entry = path.join(dir, "type-only-entry.ts");
  const types = path.join(dir, "type-only-types.ts");
  fs.writeFileSync(types, "export type T = string;\n");
  fs.writeFileSync(entry, "import type { T } from './type-only-types';\nimport './b.js';\nexport const x: T = 'x';\n");
  try {
    const g = zbundle.graph(entry);
    assert.equal(g.stats.modules, 3); // entry + b + c, NOT types
    assert.ok(!g.modules.some((m) => m.path.includes("type-only-types")));
  } finally {
    fs.unlinkSync(entry);
    fs.unlinkSync(types);
  }
});

test("graph: broken code does not stop the build (error recovery)", () => {
  const dir = path.join(FIXTURES, "chain");
  const entry = path.join(dir, "recovery-entry.js");
  fs.writeFileSync(entry, "import './b.js';\nlet oops = ;\nimport './c.js';\n");
  try {
    const g = zbundle.graph(entry);
    assert.equal(g.stats.modules, 3); // both healthy imports are there
    assert.ok(g.stats.parse_errors > 0); // and the error is reported, not hidden
    assert.ok(g.modules.find((m) => m.path.endsWith("recovery-entry.js")).parse_errors > 0);
  } finally {
    fs.unlinkSync(entry);
  }
});

// ---- graphPrint ----

test("graphPrint: indented tree, externals and cycles marked", () => {
  const out = zbundle.graphPrint(fixture("cycle", "entry.js"));
  assert.match(out, /\.\/entry\.js/);
  assert.match(out, /\(cycle\)/);
  assert.match(out, /cycles:/);
  assert.match(out, /2 modules, 2 edges/);
});

test("graphPrint: externals and dynamic import()s are visible", () => {
  const out = zbundle.graphPrint(fixture("dynamic-import", "entry.js"));
  assert.match(out, /some-vendor {2}\(external, dynamic\)/);
  assert.match(out, /\(dynamic\)/);
});

// ---- the real-world project ----

test("real project: lodash-es builds, plausible stats, zero crashes", (t) => {
  const entry = path.join(REAL, "node_modules", "lodash-es", "lodash.js");
  if (!fs.existsSync(entry)) return t.skip("corpus/real not installed (run npm install in corpus/real/)");
  const g = zbundle.graph(entry);
  // No oracle: we check orders of magnitude and invariants.
  assert.ok(g.stats.modules > 500, `${g.stats.modules} modules`);
  assert.ok(g.stats.edges > g.stats.modules, "a real graph has more edges than modules");
  assert.equal(g.stats.parse_errors, 0, "zero parse errors on real code");
  assert.equal(g.modules.length, new Set(g.modules.map((m) => m.path)).size, "no duplicate path");
  // Every edge points at a module OR an external, never both nor neither.
  for (const e of g.edges) {
    assert.ok((e.to === null) !== (e.external === null), "an edge has exactly one target");
    if (e.to !== null) assert.ok(e.to < g.modules.length);
  }
  console.log(`      lodash-es: ${g.stats.modules} modules, ${g.stats.edges} edges, ${g.stats.build_ms.toFixed(0)} ms`);
});

// ---- the surface ----

test("VERSION is exposed and matches package.json", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, "package.json"), "utf8"));
  assert.equal(zbundle.VERSION, pkg.version);
});

// ---- The two capabilities that came from zcompiler 0.2.0 ----
// These fixtures are exactly the two gaps zbundle had revealed: before 0.2.0,
// these files did not parse and NO dependency came out of them.

test("export * as ns: an export_all_as edge, carrying the export name", () => {
  const root = path.join(FIXTURES, "export-star-as");
  const g = zbundle.graph(fixture("export-star-as", "entry.js"));
  assert.equal(g.stats.parse_errors, 0);

  const math = g.edges.find((e) => e.specifier === "./math.js");
  assert.equal(math.kind, "export_all_as");
  assert.equal(math.name, "math"); // le nom d'export voyage jusqu'ici
  assert.equal(at(g, root, math.to), "math.js");

  // Bare `export * from` stays a DIFFERENT kind: it is not the same operation.
  assert.equal(g.edges.find((e) => e.specifier === "./shared.js").kind, "export_all");
  assert.equal(g.edges.find((e) => e.specifier === "./shared.js").name, null);
  // And `export { x } from` stays a re_export.
  assert.equal(g.edges.find((e) => e.specifier === "./plain.js").kind, "re_export");

  // The dependency is followed TRANSITIVELY (strings.js -> pad.js).
  assert.deepEqual(modulesOf(g, root), [
    "entry.js", "math.js", "pad.js", "plain.js", "shared.js", "strings.js",
  ].sort());
});

test("import attributes: the file parses and its attributes reach the graph", () => {
  const root = path.join(FIXTURES, "json-import");
  const g = zbundle.graph(fixture("json-import", "entry.js"));
  // THE point: zero parse errors. Before zcompiler 0.2.0, the whole entry went
  // to a syntax error and even './code.js' vanished from the graph.
  assert.equal(g.stats.parse_errors, 0);
  assert.deepEqual(modulesOf(g, root), ["code.js", "entry.js", "helper.js"]);

  const cfg = g.edges.find((e) => e.specifier === "@app/config/data.json");
  assert.deepEqual(cfg.attributes, [{ key: "type", value: "json" }]);
  assert.equal(g.edges.find((e) => e.specifier === "normalize.css/normalize.css").attributes[0].value, "css");
  // Deprecated `assert { … }` yields the SAME attributes — it is only syntax.
  const legacy = g.edges.find((e) => e.specifier === "vendor-legacy");
  assert.equal(legacy.kind, "export_all_as");
  assert.deepEqual(legacy.attributes, [{ key: "type", value: "json" }]);
  // Without a clause: empty array, nothing for the consumer to handle.
  assert.deepEqual(g.edges.find((e) => e.specifier === "./code.js").attributes, []);
});

test("import attributes: a RELATIVE '.json' still does not resolve", () => {
  // The honest boundary: zcompiler can read the syntax, but zbundle's resolution
  // table stops at JS/TS extensions. Asset loaders come later — and the error
  // says so clearly.
  const dir = path.join(FIXTURES, "json-import");
  assert.throws(
    () => zbundle.resolve(dir, "./data.json"),
    (err) => {
      assert.match(err.message, /cannot resolve '\.\/data\.json'/);
      assert.match(err.message, /data\.json\.ts/); // the attempted paths
      return true;
    },
  );
});

// ══════════════════ v0.2 : LE BUNDLE ══════════════════
// The ultimate judge (the bundle runs and says the same thing as the original)
// lives in playground/run.mjs. Here: the JS surface and the linking invariants.

const PROJECTS = path.join(__dirname, "..", "..", "playground", "projects");
const project = (name) => path.join(PROJECTS, name, "main.js");

test("bundle: a single file, JS that zcompiler re-parses without error", () => {
  const code = zbundle.bundle(project("diamond"));
  assert.equal(typeof code, "string");
  assert.ok(code.length > 0);
  // No relative `import` survives: everything is merged.
  assert.doesNotMatch(code, /from ['"]\.\.?\//);
});

test("bundle: the diamond's shared module is emitted ONLY ONCE", () => {
  const code = zbundle.bundle(project("diamond"));
  assert.equal(code.split("export const base = 10").length - 1, 0); // `export ` stripped
  assert.equal(code.split("const base = 10").length - 1, 1);
});

test("bundle: topological order — dependencies before dependents", () => {
  const code = zbundle.bundle(project("diamond"));
  const shared = code.indexOf("const base = 10");
  const b = code.indexOf("const fromB");
  const main = code.indexOf("console.log('b:'");
  assert.ok(shared >= 0 && b >= 0 && main >= 0);
  assert.ok(shared < b, "shared before b");
  assert.ok(b < main, "b before main");
});

test("bundle: collisions are renamed, free names preserved", () => {
  const { code, stats } = zbundle.bundleStats(project("barrel"));
  // Three distinct `helper`s across three modules.
  assert.match(code, /const helper = /);
  assert.match(code, /const helper\$1 = /);
  assert.match(code, /const helper\$2 = /);
  assert.ok(stats.renamed >= 2);
  // A name without collision keeps its own: the bundle stays readable.
  assert.match(code, /const VERSION = '1\.2\.3'/);
});

test("bundle: a namespace is materialized as an object", () => {
  const code = zbundle.bundle(project("barrel"));
  assert.match(code, /const strings_ns = \{/);
  assert.match(code, /strings_ns\.upper\(/);
});

test("bundle: externals are hoisted to the top and deduplicated", () => {
  const code = zbundle.bundle(project("external"));
  // `node:path` is imported by TWO modules -> a single line.
  assert.equal(code.split("from 'node:path'").length - 1, 1);
  assert.match(code, /^import .* from 'node:path';$/m);
  // And before the first module.
  assert.ok(code.indexOf("node:path") < code.indexOf("── "));
});

test("bundle: only the ENTRY's exports survive", () => {
  const code = zbundle.bundle(project("barrel"));
  // main.js exports nothing -> no `export` in the bundle.
  assert.doesNotMatch(code, /^export /m);
});

test("bundleStats: coherent measurements", () => {
  const { code, stats } = zbundle.bundleStats(project("barrel"));
  assert.equal(stats.output_bytes, Buffer.byteLength(code));
  // `modules` counts EMITTED modules: the pure barrel (`lib/index.js`, nothing
  // but re-exports) is eliminated, hence 5 and not 6.
  assert.equal(stats.modules + stats.modules_dropped, 6);
  assert.ok(stats.modules >= 4);
  assert.ok(stats.input_bytes > 0);
  assert.ok(stats.bundle_ms >= 0);
});

test("bundlePrint: statistics on top, the bundle below", () => {
  const out = zbundle.bundlePrint(project("diamond"));
  assert.match(out, /^\/\/ \d+ modules emitted \(\d+ eliminated\)/);
  assert.match(out, /tree-shaking: \d+ statements kept, \d+ eliminated/);
  assert.match(out, /bytes/);
  assert.match(out, /── /); // the module headers
});

test("bundle: one header per module, to read the bundle by eye", () => {
  const code = zbundle.bundle(project("diamond"));
  for (const f of ["shared.js", "b.js", "c.js", "main.js"]) {
    assert.ok(code.includes(`── ${f} ──`), `missing header for ${f}`);
  }
});

// ---- refusals: a CLEAR error, never a wrong bundle ----

const refusal = (name) => path.join(__dirname, "..", "..", "playground", "refusals", name, "main.js");

test("refusal: top-level await", () => {
  assert.throws(() => zbundle.bundle(refusal("top-level-await")), /top-level await/);
});

test("refusal: import.meta", () => {
  assert.throws(() => zbundle.bundle(refusal("import-meta")), /import\.meta/);
});

test("refusal: dynamic import() of an internal module", () => {
  assert.throws(
    () => zbundle.bundle(refusal("dynamic-internal")),
    (err) => {
      assert.match(err.message, /dynamic import\(\)/);
      assert.match(err.message, /code-splitting/); // dit ce qui viendra
      return true;
    },
  );
});

test("refusal: live binding exposed through a namespace object", () => {
  assert.throws(
    () => zbundle.bundle(refusal("namespace-live")),
    (err) => {
      assert.match(err.message, /namespace object/);
      assert.match(err.message, /Import the name directly/); // says what to do
      return true;
    },
  );
});

test("live binding imported BY NAME: accepted (hoisting handles it)", () => {
  // The counterpart of the refusal: without a namespace, the reassignment stays
  // visible because after merging it is THE SAME variable. run.mjs verifies it
  // at runtime.
  const code = zbundle.bundle(project("live-binding"));
  assert.match(code, /let count = 0/);
});

test("VERSION follows package.json", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, "package.json"), "utf8"));
  assert.equal(zbundle.VERSION, pkg.version);
  assert.equal(zbundle.VERSION, "0.4.2");
});

// ══════════════════ v0.3 : LE TREE-SHAKING ══════════════════
// The judge (the bundle runs and says the same thing) is still
// playground/run.mjs, which ALSO checks that dead code is textually absent.
// Here: the JS surface.

test("shaking: importing 1 name out of 20 does not drag the other 19", () => {
  const { code, stats } = zbundle.bundleStats(project("shake-barrel"));
  assert.match(code, /keptOne/);
  for (const dead of ["unused2", "unused7", "unused19", "helperOfUnused"]) {
    assert.doesNotMatch(code, new RegExp(dead), `${dead} should have disappeared`);
  }
  // The 24-module barrel shrinks to a handful.
  assert.ok(stats.modules <= 4, `${stats.modules} modules emitted`);
  assert.ok(stats.modules_dropped >= 20);
  assert.ok(stats.output_bytes < stats.input_bytes / 5, "the bundle must shrink");
});

test("shaking: a top-level side effect survives without being imported", () => {
  const code = zbundle.bundle(project("shake-sideeffect"));
  assert.match(code, /__PATCHED__/);
  assert.match(code, /registry\.push/);
  // …but the pure, unused function of the same module dies.
  assert.doesNotMatch(code, /neverUsedHelper/);
});

test("shaking: the getter trap — a member access is kept", () => {
  const code = zbundle.bundle(project("shake-getter"));
  // `source.value` may trigger a getter: removing it would change observable
  // behaviour. Conservative = correct.
  assert.match(code, /config/);
  assert.match(code, /get value/);
});

test("shaking: pure unused class removed, impure class kept", () => {
  const code = zbundle.bundle(project("shake-class"));
  assert.doesNotMatch(code, /NeverUsed/);
  // The static field CALLS: the class registers itself when defined.
  assert.match(code, /RegistersItself/);
});

test("shaking: a partially consumed export * pulls only what is used", () => {
  const code = zbundle.bundle(project("shake-star"));
  assert.match(code, /fromA/);
  assert.doesNotMatch(code, /fromB/);
  assert.doesNotMatch(code, /fromC/);
  assert.doesNotMatch(code, /unusedFromA/);
});

test("shaking: a fully dead module disappears, header included", () => {
  const code = zbundle.bundle(project("shake-diamond"));
  assert.doesNotMatch(code, /heavy\.js/); // even the header comment
  assert.doesNotMatch(code, /heavyDependency/);
  assert.match(code, /sharedUtil/); // shared with the live branch
});

test("bundleReport: what died, where, and why", () => {
  const { dead } = zbundle.bundleReport(project("shake-diamond"));
  assert.ok(dead.length > 0);
  for (const d of dead) {
    assert.equal(typeof d.module, "string");
    assert.ok(d.line >= 1);
    assert.ok(d.snippet.length > 0);
    assert.ok(d.reason.length > 0);
  }
  const heavy = dead.find((d) => d.module.includes("heavy.js"));
  assert.ok(heavy, "heavy.js must appear among the eliminations");
  assert.match(heavy.reason, /whole module eliminated/);
});

test("the shaking statistics are coherent", () => {
  const { stats } = zbundle.bundleStats(project("shake-barrel"));
  assert.ok(stats.statements_kept > 0);
  assert.ok(stats.statements_dropped > stats.statements_kept);
  assert.equal(typeof stats.modules_dropped, "number");
});

test("non-regression: the linking projects keep their behaviour", () => {
  // The diamond: the shared module is still emitted ONCE, and the (impure)
  // side-effect counter survives — that is what proves we did not over-shake.
  const code = zbundle.bundle(project("diamond"));
  assert.equal(code.split("counter.times += 1").length - 1, 1);
  assert.equal(code.split("const base = 10").length - 1, 1);
});

test("VERSION matches package.json", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, "package.json"), "utf8"));
  assert.equal(zbundle.VERSION, pkg.version);
  assert.equal(zbundle.VERSION, "0.4.2");
});

// ══════════════════ LE CLI ══════════════════
// We launch the REAL binary: the only way to check what matters for a
// command-line tool — the stdout/stderr split, the exit codes, and how readable
// the refusals are.

const { execFileSync, spawnSync } = require("node:child_process");
const os = require("node:os");

const CLI = path.join(__dirname, "dist", "cli.js");

/** Runs the CLI and returns { status, stdout, stderr } without ever throwing. */
function cli(args, cwd) {
  const r = spawnSync(process.execPath, [CLI, ...args], {
    cwd: cwd ?? path.join(__dirname, "..", "..", "playground", "projects", "shake-barrel"),
    encoding: "utf8",
  });
  return { status: r.status, stdout: r.stdout, stderr: r.stderr.replace(/\x1b\[[0-9;]*m/g, "") };
}

test("CLI: --help and --version", () => {
  const help = cli(["--help"]);
  assert.equal(help.status, 0);
  assert.match(help.stdout, /Usage:/);
  assert.match(help.stdout, /--watch/);

  const v = cli(["--version"]);
  assert.equal(v.status, 0);
  assert.equal(v.stdout.trim(), zbundle.VERSION);
});

test("CLI: with no argument, the help and an error code", () => {
  const r = cli([]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /Usage:/);
});

test("CLI: the bundle goes to stdout, the statistics to stderr", () => {
  const r = cli(["main.js"]);
  assert.equal(r.status, 0);
  // stdout is PURE JS: redirectable as is into a file.
  assert.match(r.stdout, /^\/\/ Generated by zbundle/);
  assert.doesNotMatch(r.stdout, /modules/); // no statistics inside
  // The numbers are on stderr.
  assert.match(r.stderr, /3 modules/);
  assert.match(r.stderr, /octets/);
});

test("CLI: -o writes the file and leaves stdout empty", () => {
  const out = path.join(os.tmpdir(), `zbundle-cli-${process.pid}.js`);
  try {
    const r = cli(["main.js", "-o", out]);
    assert.equal(r.status, 0);
    assert.equal(r.stdout, "");
    assert.ok(fs.existsSync(out));
    assert.match(fs.readFileSync(out, "utf8"), /keptOne/);
  } finally {
    fs.rmSync(out, { force: true });
  }
});

test("CLI: --quiet suppresses the statistics", () => {
  const r = cli(["main.js", "--quiet"]);
  assert.equal(r.status, 0);
  assert.equal(r.stderr, "");
  assert.ok(r.stdout.length > 0);
});

test("CLI: --graph prints the tree instead of bundling", () => {
  const r = cli(["main.js", "--graph"]);
  assert.equal(r.status, 0);
  assert.match(r.stdout, /main\.js/);
  assert.match(r.stdout, /modules,.*edges/);
  assert.doesNotMatch(r.stdout, /Generated by zbundle/); // no bundle
});

test("CLI: --dead lists the eliminations with their reason", () => {
  const r = cli(["main.js", "--dead", "--quiet"], path.join(__dirname, "..", "..", "playground", "projects", "shake-diamond"));
  assert.equal(r.status, 0);
  assert.match(r.stderr, /removed by tree-shaking/);
  assert.match(r.stderr, /heavy\.js/);
  assert.match(r.stderr, /whole module eliminated/);
});

test("CLI: --format iife wraps, and exports nothing", () => {
  const r = cli(["main.js", "-f", "iife"]);
  assert.equal(r.status, 0);
  assert.match(r.stdout, /\(\(\) => \{/);
  assert.match(r.stdout, /\}\)\(\);\s*$/);
  assert.doesNotMatch(r.stdout, /^export /m);
});

test("CLI: --format iife REFUSES clearly when there are externals", () => {
  const r = cli(["main.js", "-f", "iife"], path.join(__dirname, "..", "..", "playground", "projects", "external"));
  assert.equal(r.status, 1);
  assert.match(r.stderr, /incompatible with external imports/);
  assert.match(r.stderr, /--format esm/); // says what to do
  assert.equal(r.stdout, ""); // nothing invalid was emitted
});

test("CLI: an unknown format is refused", () => {
  const r = cli(["main.js", "-f", "umd"]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /unknown format 'umd'/);
  assert.match(r.stderr, /esm, iife/);
});

test("CLI: entry not found -> short message, exit code 1", () => {
  const r = cli(["./nexiste-pas.js"]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /entry not found/);
});

test("CLI: a linker refusal surfaces as is, with its explanation", () => {
  const r = cli(["main.js"], path.join(__dirname, "..", "..", "playground", "refusals", "top-level-await"));
  assert.equal(r.status, 1);
  assert.match(r.stderr, /top-level await/);
  assert.match(r.stderr, /Move it inside an/); // the advice is preserved
  assert.equal(r.stdout, "");
});

test("CLI: --watch requires -o (otherwise the bundle goes to the terminal)", () => {
  const r = cli(["main.js", "--watch"]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /--watch requires -o/);
});

test("CLI: two entries at once are refused", () => {
  const r = cli(["main.js", "autre.js"]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /only one entry/);
});

// ══════════════════ THE CONFIG LAYER ══════════════════
// `zbundle build` end to end: a config file on disk, the command, the files it
// writes. These are the cases the playground judge cannot cover — it runs ONE
// bundle per project, whereas the build layer is about several of them, about
// where they land, and about what it refuses.

/**
 * A throwaway project: sources, a config, and a `node_modules/zbundle` symlink
 * so `import { defineConfig } from "zbundle/config"` resolves exactly as it
 * would for a real user.
 */
function tmpProject(files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "zb-cfg-"));
  for (const [rel, content] of Object.entries(files)) {
    const file = path.join(dir, rel);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, content);
  }
  fs.mkdirSync(path.join(dir, "node_modules"), { recursive: true });
  fs.symlinkSync(__dirname, path.join(dir, "node_modules", "zbundle"), "dir");
  return dir;
}

/** Runs `zbundle build …` inside a throwaway project. */
function build(dir, args = []) {
  return cli(["build", ...args], dir);
}

const read = (dir, ...rel) => fs.readFileSync(path.join(dir, ...rel), "utf8");
const exists = (dir, ...rel) => fs.existsSync(path.join(dir, ...rel));

test("config: a .ts config is loaded, and defineConfig is typed identity", () => {
  const dir = tmpProject({
    "src/index.ts": `export const n: number = 41; console.log(n + 1);`,
    "zbundle.config.ts": `import { defineConfig } from "zbundle/config";
export default defineConfig({ input: "src/index.ts" });`,
  });
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  // The default output.dir is `dist`, the default name `[name].js` -> index.js.
  assert.ok(exists(dir, "dist", "index.js"), r.stderr);
  assert.equal(execFileSync(process.execPath, [path.join(dir, "dist", "index.js")], { encoding: "utf8" }), "42\n");
});

test("config: the lookup order is .ts, .mts, .js, .mjs", () => {
  const dir = tmpProject({
    "a.js": `console.log("from ts");`,
    "b.js": `console.log("from mjs");`,
    "zbundle.config.mjs": `export default { input: "b.js" };`,
    "zbundle.config.ts": `export default { input: "a.js" };`,
  });
  assert.equal(build(dir).status, 0);
  // Both exist: the .ts must win.
  assert.match(read(dir, "dist", "a.js"), /from ts/);
  assert.ok(!exists(dir, "dist", "b.js"));
});

test("config: --config forces a file, and a missing one is an error", () => {
  const dir = tmpProject({
    "x.js": `console.log("x");`,
    "custom/build.mjs": `export default { input: "../x.js", output: { dir: "../out" } };`,
  });
  assert.equal(build(dir, ["--config", "custom/build.mjs"]).status, 0);
  assert.ok(exists(dir, "out", "x.js"));

  const missing = build(dir, ["--config", "nope.ts"]);
  assert.equal(missing.status, 1);
  assert.match(missing.stderr, /config file not found: nope\.ts/);
});

test("config: an object input creates the subdirectories from its KEYS", () => {
  const dir = tmpProject({
    "src/main.ts": `console.log("main");`,
    "src/cli.ts": `console.log("cli");`,
    "zbundle.config.ts": `export default {
      input: { main: "src/main.ts", "cli/index": "src/cli.ts" },
    };`,
  });
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  assert.ok(exists(dir, "dist", "main.js"));
  // THE point of the object form: a key with a slash nests the output.
  assert.ok(exists(dir, "dist", "cli", "index.js"), "dist/cli/index.js missing");
});

test("config: multi-input produces N INDEPENDENT and correct bundles", () => {
  const dir = tmpProject({
    "shared.js": `export const tag = () => "shared";`,
    "a.js": `import { tag } from './shared.js'; console.log("a:", tag());`,
    "b.js": `import { tag } from './shared.js'; console.log("b:", tag());`,
    "zbundle.config.ts": `export default { input: ["a.js", "b.js"] };`,
  });
  assert.equal(build(dir).status, 0);
  const run = (f) => execFileSync(process.execPath, [path.join(dir, "dist", f)], { encoding: "utf8" });
  assert.equal(run("a.js"), "a: shared\n");
  assert.equal(run("b.js"), "b: shared\n");
  // Independent means each carries its own copy of the shared module: factoring
  // it out would be a shared chunk, i.e. code splitting, which is not v1.
  assert.match(read(dir, "dist", "a.js"), /shared/);
  assert.match(read(dir, "dist", "b.js"), /shared/);
});

test("config: output.entryFileNames renames, [name] is the entry's name", () => {
  const dir = tmpProject({
    "src/index.js": `console.log("hi");`,
    "zbundle.config.ts": `export default {
      input: "src/index.js",
      output: { dir: "build", entryFileNames: "[name].bundle.mjs" },
    };`,
  });
  assert.equal(build(dir).status, 0);
  assert.ok(exists(dir, "build", "index.bundle.mjs"));
});

test("config: clean empties the directory BEFORE emitting", () => {
  const dir = tmpProject({
    "m.js": `console.log("m");`,
    "zbundle.config.ts": `export default { input: "m.js", output: { clean: true } };`,
  });
  fs.mkdirSync(path.join(dir, "dist"), { recursive: true });
  fs.writeFileSync(path.join(dir, "dist", "stale.js"), "// from a previous build");
  assert.equal(build(dir).status, 0);
  assert.ok(!exists(dir, "dist", "stale.js"), "the stale file survived clean");
  assert.ok(exists(dir, "dist", "m.js"));
});

test("config: clean REFUSES to empty the working directory", () => {
  const dir = tmpProject({
    "m.js": `console.log("m");`,
    // `entryFileNames` keeps the output off the source file, so this reaches the
    // CLEAN guard rather than the earlier "never overwrite a source" one.
    "zbundle.config.ts": `export default {
      input: "m.js",
      output: { dir: ".", clean: true, entryFileNames: "[name].bundle.js" },
    };`,
  });
  const r = build(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /refusing to empty/);
  assert.match(r.stderr, /current directory/);
  // Nothing was deleted: the guard fires BEFORE any removal.
  assert.ok(exists(dir, "m.js"));
});

test("config: clean REFUSES a directory containing the cwd", () => {
  const dir = tmpProject({
    "sub/m.js": `console.log("m");`,
    "sub/zbundle.config.ts": `export default { input: "m.js", output: { dir: "..", clean: true } };`,
  });
  const r = cli(["build"], path.join(dir, "sub"));
  assert.equal(r.status, 1);
  assert.match(r.stderr, /refusing to empty/);
  assert.ok(exists(dir, "sub", "m.js"));
});

test("config: resolve.alias resolves against the CONFIG's directory, not the cwd", () => {
  const dir = tmpProject({
    "proj/src/dep.js": `export const v = 7;`,
    "proj/src/main.js": `import { v } from '@/dep.js'; console.log(v);`,
    "proj/zbundle.config.mjs": `export default {
      input: "src/main.js",
      resolve: { alias: { "@": "./src" } },
    };`,
    "elsewhere/.keep": ``,
  });
  // Run from a DIFFERENT directory: if the alias were resolved against the cwd
  // it would point at elsewhere/src and the build would fail.
  const r = cli(["build", "--config", "../proj/zbundle.config.mjs"], path.join(dir, "elsewhere"));
  assert.equal(r.status, 0, r.stderr);
  const code = read(dir, "proj", "dist", "main.js");
  assert.match(code, /const v = 7/); // inlined, not left as an external import
  assert.doesNotMatch(code, /'@\/dep\.js'/);
});

test("config: an alias key keeps its trailing separator", () => {
  const dir = tmpProject({
    "src/x.js": `export const x = 1;`,
    "main.js": `import { x } from '~/x.js'; console.log(x);`,
    "zbundle.config.ts": `export default {
      input: "main.js",
      resolve: { alias: { "~/": "./src/" } },
    };`,
  });
  // `path.resolve` strips a trailing slash; if that leaked through, `~/x.js`
  // would expand to `srcx.js` and nothing would resolve.
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  assert.match(read(dir, "dist", "main.js"), /const x = 1/);
});

test("config: an aliased specifier that is missing FAILS (never a silent external)", () => {
  const dir = tmpProject({
    "main.js": `import { x } from '@/nope.js'; console.log(x);`,
    "zbundle.config.ts": `export default {
      input: "main.js",
      resolve: { alias: { "@": "./src" } },
    };`,
  });
  const r = build(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /cannot resolve '@\/nope\.js'/);
});

test("config: resolve.extensions changes the try order", () => {
  const dir = tmpProject({
    "dep.ts": `export const which = "ts";`,
    "dep.js": `export const which = "js";`,
    "main.js": `import { which } from './dep'; console.log(which);`,
    "zbundle.config.ts": `export default {
      input: "main.js",
      resolve: { extensions: [".js", ".ts"] },
    };`,
  });
  assert.equal(build(dir).status, 0);
  // Reversed table: `.js` must now win over the default `.ts`-first order.
  assert.match(read(dir, "dist", "main.js"), /"js"/);
});

test("config: mode production turns minify on, and it is minify's ONLY effect", () => {
  const files = (mode) => ({
    "lib.js": `export const aVeryLongExportedName = () => 1;`,
    "main.js": `import { aVeryLongExportedName } from './lib.js'; console.log(aVeryLongExportedName());`,
    "zbundle.config.ts": `export default { mode: ${JSON.stringify(mode)}, input: "main.js" };`,
  });
  const dev = tmpProject(files("development"));
  const prod = tmpProject(files("production"));
  assert.equal(build(dev).status, 0);
  assert.equal(build(prod).status, 0);
  assert.match(read(dev, "dist", "main.js"), /aVeryLongExportedName/);
  assert.doesNotMatch(read(prod, "dist", "main.js"), /aVeryLongExportedName/);
  // Both still RUN and say the same thing: minify renames, it does not rewrite.
  const run = (d) => execFileSync(process.execPath, [path.join(d, "dist", "main.js")], { encoding: "utf8" });
  assert.equal(run(dev), run(prod));
});

test("config: the CLI wins over the config, which wins over the defaults", () => {
  const dir = tmpProject({
    "lib.js": `export const longNameHere = () => 1;`,
    "main.js": `import { longNameHere } from './lib.js'; console.log(longNameHere());`,
    "zbundle.config.ts": `export default {
      mode: "development",
      input: "main.js",
      output: { dir: "fromConfig" },
    };`,
  });
  // config beats the default (`dist`)
  assert.equal(build(dir).status, 0);
  assert.ok(exists(dir, "fromConfig", "main.js"));
  assert.match(read(dir, "fromConfig", "main.js"), /longNameHere/); // development

  // CLI beats the config, on both axes
  assert.equal(build(dir, ["--out-dir", "fromCli", "--minify"]).status, 0);
  assert.ok(exists(dir, "fromCli", "main.js"));
  assert.doesNotMatch(read(dir, "fromCli", "main.js"), /longNameHere/);
});

test("config: `build <entry>` bypasses the config entirely", () => {
  const dir = tmpProject({
    "other.js": `console.log("other");`,
    "direct.js": `console.log("direct");`,
    "zbundle.config.ts": `export default { input: "other.js", output: { dir: "never" } };`,
  });
  const r = build(dir, ["direct.js"]);
  assert.equal(r.status, 0, r.stderr);
  assert.ok(exists(dir, "dist", "direct.js"));
  assert.ok(!exists(dir, "never"), "the config was read even though an entry was given");

  // Combining the two would make the precedence ambiguous, so it is refused.
  const both = build(dir, ["direct.js", "--config", "zbundle.config.ts"]);
  assert.equal(both.status, 1);
  assert.match(both.stderr, /cannot be combined/);
});

test("config: no config file at all is a clear error, with the names tried", () => {
  const dir = tmpProject({ "m.js": `console.log(1);` });
  const r = build(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /no config file found/);
  assert.match(r.stderr, /zbundle\.config\.ts/);
  assert.match(r.stderr, /zbundle build src\/index\.ts/); // the way out
});

// ---- the RESERVED options: each one errors, and names its version ----

const RESERVED_CASES = [
  ["watch", `{ input: "m.js", watch: true }`, /watch: reserved — planned for v0\.5/],
  ["output.chunkFileNames", `{ input: "m.js", output: { chunkFileNames: "[name].js" } }`, /chunkFileNames: reserved — planned for v0\.6/],
  ["output.assetFileNames", `{ input: "m.js", output: { assetFileNames: "[name][ext]" } }`, /assetFileNames: reserved — planned for v0\.6/],
];

for (const [name, body, expected] of RESERVED_CASES) {
  test(`config: ${name} is RESERVED — an error, never a silent no-op`, () => {
    const dir = tmpProject({ "m.js": `console.log(1);`, "zbundle.config.ts": `export default ${body};` });
    const r = build(dir);
    assert.equal(r.status, 1, `expected exit 1, got ${r.status}`);
    assert.match(r.stderr, expected);
    assert.match(r.stderr, /issues/); // where to follow it
    assert.ok(!exists(dir, "dist"), "something was emitted despite the refusal");
  });
}

test("config: watch set to FALSE is accepted (that is the behaviour)", () => {
  const dir = tmpProject({
    "m.js": `console.log(1);`,
    "zbundle.config.ts": `export default { input: "m.js", watch: false };`,
  });
  assert.equal(build(dir).status, 0);
});

test("config: a format other than esm is refused, and says where iife lives", () => {
  const dir = tmpProject({
    "m.js": `console.log(1);`,
    "zbundle.config.ts": `export default { input: "m.js", output: { format: "cjs" } };`,
  });
  const r = build(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /output\.format: "cjs"/);
  assert.match(r.stderr, /only "esm" is supported/);
  assert.match(r.stderr, /-f iife/); // the escape hatch that DOES exist
});

test("config: an unknown placeholder in entryFileNames is refused", () => {
  const dir = tmpProject({
    "m.js": `console.log(1);`,
    "zbundle.config.ts": `export default { input: "m.js", output: { entryFileNames: "[name].[hash].js" } };`,
  });
  const r = build(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /unknown placeholder \[hash\]/);
});

// ---- unknown keys: a WARNING with a suggestion, and the build goes on ----

test("config: an unknown key warns with the closest name, and still builds", () => {
  const dir = tmpProject({
    "m.js": `console.log(1);`,
    "zbundle.config.ts": `export default { input: "m.js", minfy: true, outpout: {} };`,
  });
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /unknown option minfy — did you mean minify\?/);
  assert.match(r.stderr, /unknown option outpout — did you mean output\?/);
  assert.ok(exists(dir, "dist", "m.js"), "a typo must not stop the build");
});

test("config: a nested unknown key is reported with its full path", () => {
  const dir = tmpProject({
    "m.js": `console.log(1);`,
    "zbundle.config.ts": `export default { input: "m.js", resolve: { aliass: {} } };`,
  });
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /unknown option resolve\.aliass — did you mean resolve\.alias\?/);
});

// ---- wrong values: an error naming the path and both types ----

const TYPE_CASES = [
  [`{ input: 42 }`, /input: expected string \| string\[\] \| Record/],
  [`{ input: "m.js", minify: "yes" }`, /minify: expected boolean, received string/],
  [`{ input: "m.js", mode: "prod" }`, /mode: expected "development" \| "production"/],
  [`{ input: "m.js", output: { dir: 3 } }`, /output\.dir: expected string, received number/],
  [`{ input: "m.js", resolve: { extensions: "ts" } }`, /resolve\.extensions: expected array of strings/],
  [`{ input: "m.js", resolve: { extensions: ["ts"] } }`, /must start with a dot/],
  [`{ input: "m.js", resolve: { extensions: [] } }`, /cannot be empty/],
];

for (const [body, expected] of TYPE_CASES) {
  test(`config: wrong value refused — ${body.slice(0, 46)}`, () => {
    const dir = tmpProject({ "m.js": `console.log(1);`, "zbundle.config.ts": `export default ${body};` });
    const r = build(dir);
    assert.equal(r.status, 1, `expected exit 1, got ${r.status}: ${r.stderr}`);
    assert.match(r.stderr, expected);
  });
}

test("config: a config exporting something that is not an object is refused", () => {
  const dir = tmpProject({ "m.js": `console.log(1);`, "zbundle.config.ts": `export default 42;` });
  const r = build(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /must export an object, received number/);
});

test("config: a missing entry file names the path", () => {
  const dir = tmpProject({ "zbundle.config.ts": `export default { input: "src/gone.ts" };` });
  const r = build(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /entry not found/);
  assert.match(r.stderr, /gone\.ts/);
});

test("config: two entries writing to the SAME file is refused", () => {
  const dir = tmpProject({
    "src/a/index.ts": `console.log("A");`,
    "src/b/index.ts": `console.log("B");`,
    "zbundle.config.ts": `export default { input: ["src/a/index.ts", "src/b/index.ts"] };`,
  });
  // Both entries are named `index`, so both would land on dist/index.js and the
  // second would silently overwrite the first — while the recap claims 2 bundles.
  const r = build(dir);
  assert.equal(r.status, 1, r.stderr);
  assert.match(r.stderr, /two entries would be written to the same file/);
  assert.match(r.stderr, /Both entries are named "index"/);
  assert.match(r.stderr, /object form of `input`/);
  assert.ok(!exists(dir, "dist"), "something was emitted despite the collision");
});

test("config: entryFileNames without [name] collides, and says so", () => {
  const dir = tmpProject({
    "a.ts": `console.log("A");`,
    "b.ts": `console.log("B");`,
    "zbundle.config.ts": `export default {
      input: ["a.ts", "b.ts"],
      output: { entryFileNames: "bundle.js" },
    };`,
  });
  const r = build(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /it has no \[name\]/);
  // A SINGLE entry with a fixed name is legitimate and must still work.
  fs.writeFileSync(
    path.join(dir, "zbundle.config.ts"),
    `export default { input: "a.ts", output: { entryFileNames: "bundle.js" } };`,
  );
  assert.equal(build(dir).status, 0);
  assert.ok(exists(dir, "dist", "bundle.js"));
});

test("config: a collision is caught BEFORE clean deletes anything", () => {
  const dir = tmpProject({
    "src/a/index.ts": `console.log("A");`,
    "src/b/index.ts": `console.log("B");`,
    "zbundle.config.ts": `export default {
      input: ["src/a/index.ts", "src/b/index.ts"],
      output: { clean: true },
    };`,
  });
  fs.mkdirSync(path.join(dir, "dist"), { recursive: true });
  fs.writeFileSync(path.join(dir, "dist", "previous.js"), "// the previous build");
  const r = build(dir);
  assert.equal(r.status, 1);
  // A config that cannot produce a coherent result must not have destroyed the
  // result of the one that could.
  assert.ok(exists(dir, "dist", "previous.js"), "clean ran before the config was rejected");
});

test("config: a .cjs config is DISCOVERED, not just loadable with --config", () => {
  const dir = tmpProject({
    "m.js": `console.log("cjs");`,
    // `"type": "module"` is exactly the project where .cjs is the only way to
    // write `module.exports` — and where a member is most likely to reach for it.
    "package.json": `{ "type": "module" }`,
    "zbundle.config.cjs": `/** @type {import("zbundle/config").Config} */
module.exports = { input: "m.js" };`,
  });
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  assert.ok(exists(dir, "dist", "m.js"));
});

test("config: .cjs comes LAST in the lookup order", () => {
  const dir = tmpProject({
    "a.js": `console.log("ts wins");`,
    "b.js": `console.log("cjs");`,
    "zbundle.config.cjs": `module.exports = { input: "b.js" };`,
    "zbundle.config.ts": `export default { input: "a.js" };`,
  });
  assert.equal(build(dir).status, 0);
  assert.ok(exists(dir, "dist", "a.js"));
  assert.ok(!exists(dir, "dist", "b.js"));
});

test("config: the 'no config found' message lists every name actually tried", () => {
  const dir = tmpProject({ "m.js": `console.log(1);` });
  const r = build(dir);
  assert.equal(r.status, 1);
  // Derived from CONFIG_NAMES, so the message can never drift from the lookup.
  for (const ext of ["ts", "mts", "js", "mjs", "cjs"]) {
    assert.match(r.stderr, new RegExp(`zbundle\\.config\\.${ext}`));
  }
});

test("config: a .cts config says WHY it cannot work, and what to use instead", () => {
  const dir = tmpProject({
    "m.js": `console.log(1);`,
    "zbundle.config.cts": `import { defineConfig } from "zbundle/config";
export default defineConfig({ input: "m.js" });`,
  });
  // Not discovered (absent from CONFIG_NAMES)…
  assert.match(build(dir).stderr, /no config file found/);
  // …and forcing it gives a real explanation, not Node's raw complaint alone.
  const forced = build(dir, ["--config", "zbundle.config.cts"]);
  assert.equal(forced.status, 1);
  assert.match(forced.stderr, /A \.cts config cannot work/);
  assert.match(forced.stderr, /zbundle\.config\.cjs with JSDoc types/);
});

// ---- nothing escapes output.dir, and no source is ever overwritten ----

test("config: an input KEY cannot escape output.dir", () => {
  const dir = tmpProject({
    "m.js": `console.log(1);`,
    "zbundle.config.ts": `export default { input: { "../escape": "m.js" } };`,
  });
  const r = build(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /is outside output\.dir/);
  assert.ok(!exists(dir, "escape.js"), "a file was written outside output.dir");
});

test("config: entryFileNames cannot escape output.dir either", () => {
  const dir = tmpProject({
    "m.js": `console.log(1);`,
    "zbundle.config.ts": `export default { input: "m.js", output: { entryFileNames: "../escape.js" } };`,
  });
  const r = build(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /is outside output\.dir/);
  assert.ok(!exists(dir, "escape.js"));
});

test("config: a name MAY create subdirectories — it just may not leave", () => {
  const dir = tmpProject({
    "m.js": `console.log(1);`,
    "zbundle.config.ts": `export default { input: { "cli/deep/index": "m.js" } };`,
  });
  assert.equal(build(dir).status, 0);
  assert.ok(exists(dir, "dist", "cli", "deep", "index.js"));
});

test("config: an absolute entryFileNames is refused (it is a name, not a path)", () => {
  const dir = tmpProject({
    "m.js": `console.log(1);`,
    "zbundle.config.ts": `export default { input: "m.js", output: { entryFileNames: "/tmp/x.js" } };`,
  });
  const r = build(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /is absolute/);
});

test("config: a bundle is NEVER written over a source file", () => {
  const dir = tmpProject({
    "m.js": `console.log("the original source");`,
    // `output.dir: "."` + the default `[name].js` targets m.js itself.
    "zbundle.config.ts": `export default { input: "m.js", output: { dir: "." } };`,
  });
  const r = build(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /written over a source file/);
  // There is no undo for this one: the source must be untouched.
  assert.match(read(dir, "m.js"), /the original source/);
});

test("config: output.dir cannot be empty (it used to overwrite the sources)", () => {
  const dir = tmpProject({
    "m.js": `console.log("the original source");`,
    "zbundle.config.ts": `export default { input: "m.js", output: { dir: "" } };`,
  });
  const r = build(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /output\.dir: cannot be empty/);
  assert.match(read(dir, "m.js"), /the original source/);
});

test("config: empty names are refused rather than producing nameless files", () => {
  const empty = tmpProject({
    "m.js": `console.log(1);`,
    "zbundle.config.ts": `export default { input: "m.js", output: { entryFileNames: "" } };`,
  });
  assert.match(build(empty).stderr, /entryFileNames: cannot be empty/);

  const key = tmpProject({
    "m.js": `console.log(1);`,
    "zbundle.config.ts": `export default { input: { "": "m.js" } };`,
  });
  assert.match(build(key).stderr, /entry name cannot be empty/);

  const path_ = tmpProject({ "zbundle.config.ts": `export default { input: "" };` });
  assert.match(build(path_).stderr, /entry path cannot be empty/);
});

test("config: output.dir pointing at a FILE says so, instead of a raw EEXIST", () => {
  const dir = tmpProject({
    "m.js": `console.log(1);`,
    "taken": `not a directory`,
    "zbundle.config.ts": `export default { input: "m.js", output: { dir: "taken" } };`,
  });
  const r = build(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /exists and is not a directory/);
  assert.doesNotMatch(r.stderr, /EEXIST/);
});

test("config: an array config points at multi-input; a function config says so", () => {
  const arr = tmpProject({
    "m.js": `console.log(1);`,
    "zbundle.config.ts": `export default [{ input: "m.js" }];`,
  });
  const a = build(arr);
  assert.equal(a.status, 1);
  assert.match(a.stderr, /received array/);
  assert.match(a.stderr, /several inputs/);

  const fn = tmpProject({
    "m.js": `console.log(1);`,
    "zbundle.config.ts": `export default () => ({ input: "m.js" });`,
  });
  const f = build(fn);
  assert.equal(f.status, 1);
  assert.match(f.stderr, /function config is not supported/);
});

test("config: a config exporting a Promise is awaited", () => {
  const dir = tmpProject({
    "m.js": `console.log("async");`,
    // Not a documented feature, but it falls out of `await` flattening and a
    // config that computes something asynchronously is a reasonable thing to
    // write. Pinned so it cannot regress silently.
    "zbundle.config.ts": `export default Promise.resolve({ input: "m.js" });`,
  });
  assert.equal(build(dir).status, 0);
  assert.ok(exists(dir, "dist", "m.js"));
});

// ---- an option that is accepted must ACT — the CLI included ----

const FOREIGN_ON_BUILD = [
  ["--graph", /--graph does not apply here/],
  ["-o", /-o\/--out does not apply here/],
  ["-f", /-f\/--format does not apply here/],
  ["--watch", /--watch does not apply here/],
];

for (const [flag, expected] of FOREIGN_ON_BUILD) {
  test(`CLI: \`build ${flag}\` is refused, not silently ignored`, () => {
    const dir = tmpProject({
      "m.js": `console.log(1);`,
      "zbundle.config.ts": `export default { input: "m.js" };`,
    });
    // Flags taking a value need one, or parseArgs complains about the wrong thing.
    const args = flag === "-o" ? ["-o", "out.js"] : flag === "-f" ? ["-f", "iife"] : [flag];
    const r = build(dir, args);
    assert.equal(r.status, 1, `\`build ${flag}\` exited ${r.status} — it was ignored`);
    assert.match(r.stderr, expected);
    assert.ok(!exists(dir, "dist"), "a bundle was emitted despite the refusal");
  });
}

test("CLI: `build --watch` names the version it is planned for", () => {
  const dir = tmpProject({
    "m.js": `console.log(1);`,
    "zbundle.config.ts": `export default { input: "m.js" };`,
  });
  const r = build(dir, ["--watch"]);
  assert.match(r.stderr, /planned for v0\.5/);
  // The interim answer is given rather than left to be guessed.
  assert.match(r.stderr, /zbundle <entry> --watch -o <file>/);
});

test("CLI: build-only flags are refused on the one-shot form", () => {
  const dir = tmpProject({
    "m.js": `console.log(1);`,
    "zbundle.config.ts": `export default { input: "m.js" };`,
  });
  const cfg = cli(["m.js", "--config", "zbundle.config.ts"], dir);
  assert.equal(cfg.status, 1);
  assert.match(cfg.stderr, /-c\/--config does not apply here/);
  assert.equal(cfg.stdout, "", "invalid JS reached stdout");

  const outDir = cli(["m.js", "--out-dir", "d"], dir);
  assert.equal(outDir.status, 1);
  assert.match(outDir.stderr, /--out-dir does not apply here/);
});

test("CLI: `build --dead` really lists what tree-shaking removed", () => {
  const dir = tmpProject({
    "m.js": `const deadThing = () => "never";\nconsole.log("ok");`,
    "zbundle.config.ts": `export default { input: "m.js" };`,
  });
  const r = build(dir, ["--dead"]);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /removed by tree-shaking/);
  assert.match(r.stderr, /deadThing/);
  // And the bundle is still produced, correctly.
  assert.ok(exists(dir, "dist", "m.js"));
  assert.doesNotMatch(read(dir, "dist", "m.js"), /deadThing/);
});

test("CLI: --quiet and --minify apply to BOTH forms", () => {
  const dir = tmpProject({
    "lib.js": `export const aLongExportedName = () => 1;`,
    "m.js": `import { aLongExportedName } from './lib.js'; console.log(aLongExportedName());`,
    "zbundle.config.ts": `export default { input: "m.js" };`,
  });
  const b = build(dir, ["--minify", "--quiet"]);
  assert.equal(b.status, 0, b.stderr);
  assert.equal(b.stderr, "", "--quiet left output on stderr");
  assert.doesNotMatch(read(dir, "dist", "m.js"), /aLongExportedName/);

  const one = cli(["m.js", "--minify", "--quiet"], dir);
  assert.equal(one.status, 0);
  assert.equal(one.stderr, "");
  assert.doesNotMatch(one.stdout, /aLongExportedName/);
});

// ══════════════════ tsconfig.json ══════════════════
// What a STRIPPER reads from a tsconfig: baseUrl/paths, jsx, jsxImportSource.
// Everything else is ignored BY CONTRACT, and these tests pin both halves.

test("tsconfig: paths with a wildcard become a resolution prefix", () => {
  const dir = tmpProject({
    "src/util.ts": `export const helper = (n: number) => n * 2;`,
    "src/main.ts": `import { helper } from '@/util.ts'; console.log(helper(21));`,
    "tsconfig.json": `{ "compilerOptions": { "baseUrl": ".", "paths": { "@/*": ["./src/*"] } } }`,
    "zbundle.config.ts": `export default { input: "src/main.ts" };`,
  });
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  // Inlined, not left as an external import: the tsconfig did the resolving.
  assert.match(read(dir, "dist", "main.js"), /n \* 2/);
  assert.equal(execFileSync(process.execPath, [path.join(dir, "dist", "main.js")], { encoding: "utf8" }), "42\n");
});

test("tsconfig: a path WITHOUT a wildcard is an exact mapping", () => {
  const dir = tmpProject({
    "vendor/jq.ts": `export const jq = () => "jq";`,
    "src/main.ts": `import { jq } from 'jquery'; console.log(jq());`,
    "tsconfig.json": `{ "compilerOptions": { "paths": { "jquery": ["./vendor/jq.ts"] } } }`,
    "zbundle.config.ts": `export default { input: "src/main.ts" };`,
  });
  assert.equal(build(dir).status, 0);
  assert.match(read(dir, "dist", "main.js"), /"jq"/);
});

test("tsconfig: an exact mapping does not swallow a longer specifier", () => {
  const dir = tmpProject({
    "vendor/jq.ts": `export const jq = () => "jq";`,
    // `jquery-ui` is a DIFFERENT package: it must stay external, not be
    // captured by the `jquery` mapping.
    "src/main.ts": `import { jq } from 'jquery'; import 'jquery-ui'; console.log(jq());`,
    "tsconfig.json": `{ "compilerOptions": { "paths": { "jquery": ["./vendor/jq.ts"] } } }`,
    "zbundle.config.ts": `export default { input: "src/main.ts" };`,
  });
  assert.equal(build(dir).status, 0);
  assert.match(read(dir, "dist", "main.js"), /'jquery-ui'/);
});

test("tsconfig: JSONC — comments and trailing commas are legal", () => {
  const dir = tmpProject({
    "src/dep.ts": `export const v = 1;`,
    "src/main.ts": `import { v } from '@/dep.ts'; console.log(v);`,
    "tsconfig.json": `{
      // a line comment, and a URL that must survive: http://example.com
      /* a block comment */
      "compilerOptions": {
        "paths": { "@/*": ["./src/*"], },
      },
    }`,
    "zbundle.config.ts": `export default { input: "src/main.ts" };`,
  });
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  assert.match(read(dir, "dist", "main.js"), /const v = 1/);
});

test("tsconfig: malformed JSONC names the position", () => {
  const dir = tmpProject({
    "src/main.ts": `console.log(1);`,
    "tsconfig.json": `{ "compilerOptions": { "paths": { "@/*": ["./src/*"] }`,
    "zbundle.config.ts": `export default { input: "src/main.ts" };`,
  });
  const r = build(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /tsconfig\.json:\d+:\d+/);
});

test("tsconfig: extends resolves paths against the file that DECLARED them", () => {
  const dir = tmpProject({
    "cfg/base.json": `{ "compilerOptions": { "paths": { "@/*": ["../src/*"] } } }`,
    "tsconfig.json": `{ "extends": "./cfg/base.json" }`,
    "src/dep.ts": `export const v = 7;`,
    "src/main.ts": `import { v } from '@/dep.ts'; console.log(v);`,
    "zbundle.config.ts": `export default { input: "src/main.ts" };`,
  });
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  // `../src/*` only works when resolved against cfg/, not against the root.
  assert.match(read(dir, "dist", "main.js"), /const v = 7/);
});

test("tsconfig: a circular extends is an error naming the loop", () => {
  const dir = tmpProject({
    "src/main.ts": `console.log(1);`,
    "tsconfig.json": `{ "extends": "./b.json" }`,
    "b.json": `{ "extends": "./tsconfig.json" }`,
    "zbundle.config.ts": `export default { input: "src/main.ts" };`,
  });
  const r = build(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /circular extends/);
  assert.match(r.stderr, /b\.json/);
});

test('tsconfig: "jsx": "preserve" is refused, and says it always will be', () => {
  const dir = tmpProject({
    "main.jsx": `console.log(1);`,
    "tsconfig.json": `{ "compilerOptions": { "jsx": "preserve" } }`,
    "zbundle.config.ts": `export default { input: "main.jsx" };`,
  });
  const r = build(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /"jsx": "preserve" is not supported/);
  assert.match(r.stderr, /will not be/); // not a "planned for vX" promise
});

test('tsconfig: "jsx": "react" warns that the automatic runtime is used anyway', () => {
  const dir = tmpProject({
    "main.jsx": `console.log(1);`,
    "tsconfig.json": `{ "compilerOptions": { "jsx": "react" } }`,
    "zbundle.config.ts": `export default { input: "main.jsx" };`,
  });
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /classic runtime/);
  assert.match(r.stderr, /automatic one/);
});

test("tsconfig: several path targets — the first is used, and it is said", () => {
  const dir = tmpProject({
    "src/dep.ts": `export const v = 1;`,
    "other/dep.ts": `export const v = 2;`,
    "src/main.ts": `import { v } from '@/dep.ts'; console.log(v);`,
    "tsconfig.json": `{ "compilerOptions": { "paths": { "@/*": ["./src/*", "./other/*"] } } }`,
    "zbundle.config.ts": `export default { input: "src/main.ts" };`,
  });
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /lists 2 targets/);
  assert.match(read(dir, "dist", "main.js"), /const v = 1/); // the first one
});

test("tsconfig: TWO tsconfigs, each governing its own package", () => {
  const dir = tmpProject({
    "pkgs/a/tsconfig.json": `{ "compilerOptions": { "paths": { "#own/*": ["./src/*"] } } }`,
    "pkgs/b/tsconfig.json": `{ "compilerOptions": { "paths": { "#own/*": ["./src/*"] } } }`,
    "pkgs/a/src/own.ts": `export const tag = () => "A";`,
    "pkgs/b/src/own.ts": `export const tag = () => "B";`,
    "pkgs/b/src/index.ts": `import { tag } from '#own/own.ts'; export const b = () => tag();`,
    "pkgs/a/src/main.ts":
      `import { tag } from '#own/own.ts';\n` +
      `import { b } from '../../b/src/index.ts';\n` +
      `console.log(tag(), b());`,
    "zbundle.config.ts": `export default { input: "pkgs/a/src/main.ts" };`,
  });
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  // The SAME key `#own/` means two different directories. A global alias table
  // could not express that; scoped aliases can.
  assert.equal(
    execFileSync(process.execPath, [path.join(dir, "dist", "main.js")], { encoding: "utf8" }),
    "A B\n",
  );
});

test("tsconfig: resolve.alias WINS over the tsconfig paths", () => {
  const dir = tmpProject({
    "src/dep.ts": `export const v = 1;`,
    "chosen/dep.ts": `export const v = 999;`,
    "src/main.ts": `import { v } from '@/dep.ts'; console.log(v);`,
    "tsconfig.json": `{ "compilerOptions": { "paths": { "@/*": ["./src/*"] } } }`,
    "zbundle.config.ts": `export default {
      input: "src/main.ts",
      resolve: { alias: { "@/": "./chosen/" } },
    };`,
  });
  assert.equal(build(dir).status, 0);
  // Whoever wrote the zbundle config knew what they were doing.
  assert.match(read(dir, "dist", "main.js"), /const v = 999/);
});

test("tsconfig: jsx.importSource in the config WINS over the tsconfig's", () => {
  const dir = tmpProject({
    "main.jsx": `const A = () => <b>x</b>; console.log(typeof A);`,
    "tsconfig.json": `{ "compilerOptions": { "jsxImportSource": "preact" } }`,
    "zbundle.config.ts": `export default { input: "main.jsx", jsx: { importSource: "chosen" } };`,
  });
  assert.equal(build(dir).status, 0);
  const code = read(dir, "dist", "main.js");
  assert.match(code, /'chosen\/jsx-runtime'/);
  assert.doesNotMatch(code, /'preact\/jsx-runtime'/);
});

test("tsconfig: false ignores it entirely", () => {
  const dir = tmpProject({
    "src/dep.ts": `export const v = 1;`,
    "src/main.ts": `import { v } from '@/dep.ts'; console.log(v);`,
    "tsconfig.json": `{ "compilerOptions": { "paths": { "@/*": ["./src/*"] } } }`,
    "zbundle.config.ts": `export default { input: "src/main.ts", tsconfig: false };`,
  });
  assert.equal(build(dir).status, 0);
  // Not resolved, so `@/dep.ts` stays a bare specifier: external, still imported.
  assert.match(read(dir, "dist", "main.js"), /'@\/dep\.ts'/);
});

test("tsconfig: an explicit path is used, and a missing one is an error", () => {
  const dir = tmpProject({
    "src/dep.ts": `export const v = 3;`,
    "src/main.ts": `import { v } from '@/dep.ts'; console.log(v);`,
    "custom/ts.json": `{ "compilerOptions": { "paths": { "@/*": ["../src/*"] } } }`,
    "zbundle.config.ts": `export default { input: "src/main.ts", tsconfig: "custom/ts.json" };`,
  });
  assert.equal(build(dir).status, 0);
  assert.match(read(dir, "dist", "main.js"), /const v = 3/);

  fs.writeFileSync(
    path.join(dir, "zbundle.config.ts"),
    `export default { input: "src/main.ts", tsconfig: "nope.json" };`,
  );
  const missing = build(dir);
  assert.equal(missing.status, 1);
  assert.match(missing.stderr, /tsconfig: not found/);
});

test("tsconfig: everything outside the closed list is ignored in silence", () => {
  const dir = tmpProject({
    "src/main.ts": `export const x: number = 1; console.log(x);`,
    // Not one of these changes what zbundle does, and none may warn: ignoring
    // them is the contract, not an oversight.
    "tsconfig.json": `{ "compilerOptions": {
      "target": "ES5", "module": "commonjs", "strict": true,
      "lib": ["dom"], "types": ["node"], "declaration": true,
      "allowJs": true, "checkJs": true, "composite": true
    } }`,
    "zbundle.config.ts": `export default { input: "src/main.ts" };`,
  });
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  assert.doesNotMatch(r.stderr, /⚠|unknown|ignored/);
  // ES5 target notwithstanding: there is no downleveling, the arrow survives.
  assert.ok(exists(dir, "dist", "main.js"));
});

test("tsconfig: the alias scope is CANONICAL, like the module paths it is compared to", () => {
  const dir = tmpProject({
    "node_modules/@repo/tsconfig/package.json": `{ "name": "@repo/tsconfig" }`,
    // Reached through `require.resolve`, which canonicalises. The scope comes
    // from the extending file, which does not — and `resolver.zig` compares the
    // scope against module directories that went through `realPath`. A
    // non-canonical scope would simply never match, in silence.
    "node_modules/@repo/tsconfig/tsconfig.json": `{ "compilerOptions": { "paths": { "@/*": ["../../../src/*"] } } }`,
    "tsconfig.json": `{ "extends": "@repo/tsconfig" }`,
    "src/dep.ts": `export const v = 5;`,
    "src/main.ts": `import { v } from '@/dep.ts'; console.log(v);`,
    "zbundle.config.ts": `export default { input: "src/main.ts" };`,
  });
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  assert.match(read(dir, "dist", "main.js"), /const v = 5/);
});

test("tsconfig: extends an npm PACKAGE, by name or by file", () => {
  const files = (ext) => ({
    "node_modules/@repo/tsconfig/package.json": `{ "name": "@repo/tsconfig" }`,
    "node_modules/@repo/tsconfig/tsconfig.json": `{ "compilerOptions": { "paths": { "@/*": ["../../../src/*"] } } }`,
    "tsconfig.json": `{ "extends": ${JSON.stringify(ext)} }`,
    "src/dep.ts": `export const v = 6;`,
    "src/main.ts": `import { v } from '@/dep.ts'; console.log(v);`,
    "zbundle.config.ts": `export default { input: "src/main.ts" };`,
  });
  for (const ext of ["@repo/tsconfig", "@repo/tsconfig/tsconfig.json"]) {
    const dir = tmpProject(files(ext));
    assert.equal(build(dir).status, 0, `extends ${ext}`);
    assert.match(read(dir, "dist", "main.js"), /const v = 6/);
  }
});

test("tsconfig: a malformed paths entry is skipped, but never in silence", () => {
  for (const [bad, expected] of [
    [`"./src/*"`, /must map to an ARRAY/],
    [`[42]`, /lists no string target/],
    [`[]`, /has no target/],
  ]) {
    const dir = tmpProject({
      "src/main.ts": `console.log(1);`,
      "tsconfig.json": `{ "compilerOptions": { "paths": { "@/*": ${bad} } } }`,
      "zbundle.config.ts": `export default { input: "src/main.ts" };`,
    });
    const r = build(dir);
    // Validating a tsconfig is `tsc`'s job, so the build goes on…
    assert.equal(r.status, 0, r.stderr);
    // …but the only other symptom would be a "cannot resolve" with nothing
    // pointing back at the malformed entry.
    assert.match(r.stderr, expected);
  }
});

test("tsconfig: a JSONC string keeps its content (a real parser, not a regex)", () => {
  const dir = tmpProject({
    "src/dep.ts": `export const v = 8;`,
    "src/main.ts": `import { v } from '@/dep.ts'; console.log(v);`,
    // `//` and `/*` INSIDE strings must not be taken for comments — the exact
    // thing a comment-stripping regex gets wrong.
    "tsconfig.json": `{
      "$schema": "http://json.schemastore.org/tsconfig",
      "x": "a/*not a comment*/b",
      "compilerOptions": { "paths": { "@/*": ["./src/*"] } }
    }`,
    "zbundle.config.ts": `export default { input: "src/main.ts" };`,
  });
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  assert.match(read(dir, "dist", "main.js"), /const v = 8/);
});

// ══════════════════ SOURCE MAPS ══════════════════
// A map that merely parses proves nothing. Every case below decodes it with the
// standard `source-map` consumer and checks it points somewhere TRUE.

const { SourceMapConsumer } = require("source-map");

/** A tiny TS project whose positions we know by heart. */
function mapProject(sourcemap) {
  return tmpProject({
    "src/dep.ts": `export const helper = (n: number): number => n * 2;\nexport const unused = () => "dead";\n`,
    "src/main.ts": `import { helper } from './dep.ts';\nconst answer = helper(21);\nconsole.log(answer);\n`,
    "zbundle.config.ts": `export default { input: "src/main.ts", sourcemap: ${sourcemap} };`,
  });
}

test("sourcemap: false emits nothing, and the bundle is byte-identical", () => {
  const off = mapProject("false");
  const absent = tmpProject({
    "src/dep.ts": `export const helper = (n: number): number => n * 2;\nexport const unused = () => "dead";\n`,
    "src/main.ts": `import { helper } from './dep.ts';\nconst answer = helper(21);\nconsole.log(answer);\n`,
    "zbundle.config.ts": `export default { input: "src/main.ts" };`,
  });
  assert.equal(build(off).status, 0);
  assert.equal(build(absent).status, 0);
  assert.ok(!exists(off, "dist", "main.js.map"));
  assert.doesNotMatch(read(off, "dist", "main.js"), /sourceMappingURL/);
  // Asking for no map must cost nothing at all — not one byte.
  assert.equal(read(off, "dist", "main.js"), read(absent, "dist", "main.js"));
});

test("sourcemap: true writes a .map and points at it", () => {
  const dir = mapProject("true");
  assert.equal(build(dir).status, 0);
  assert.ok(exists(dir, "dist", "main.js.map"));
  assert.match(read(dir, "dist", "main.js"), /\/\/# sourceMappingURL=main\.js\.map/);
});

test("sourcemap: inline embeds a data URL and writes no file", () => {
  const dir = mapProject(`"inline"`);
  assert.equal(build(dir).status, 0);
  assert.ok(!exists(dir, "dist", "main.js.map"));
  const code = read(dir, "dist", "main.js");
  const m = code.match(/sourceMappingURL=data:application\/json;charset=utf-8;base64,([A-Za-z0-9+/=]+)/);
  assert.ok(m, "no inline data URL");
  const map = JSON.parse(Buffer.from(m[1], "base64").toString("utf8"));
  assert.equal(map.version, 3);
  assert.ok(map.mappings.length > 0);
});

test("sourcemap: hidden writes the .map but adds NO comment", () => {
  const dir = mapProject(`"hidden"`);
  assert.equal(build(dir).status, 0);
  assert.ok(exists(dir, "dist", "main.js.map"));
  // The point of `hidden`: the map exists for whoever uploads it, and nothing
  // in the shipped bundle announces it.
  assert.doesNotMatch(read(dir, "dist", "main.js"), /sourceMappingURL/);
});

test("sourcemap: the v3 shape is complete and self-contained", () => {
  const dir = mapProject("true");
  assert.equal(build(dir).status, 0);
  const map = JSON.parse(read(dir, "dist", "main.js.map"));
  assert.equal(map.version, 3);
  assert.equal(map.file, "main.js");
  assert.deepEqual([...map.sources].sort(), ["../src/dep.ts", "../src/main.ts"]);
  // `sources` are relative to the MAP, not to the cwd: that is where a debugger
  // resolves them from.
  assert.ok(map.sources.every((s) => !path.isAbsolute(s)));
  assert.equal(map.sourcesContent.length, map.sources.length);
  assert.match(map.sourcesContent.join(""), /helper/);
  assert.deepEqual(map.names, []);
});

test("sourcemap: END TO END — a bundle position lands on the right character", async () => {
  const dir = mapProject("true");
  assert.equal(build(dir).status, 0);
  const code = read(dir, "dist", "main.js");
  const map = JSON.parse(read(dir, "dist", "main.js.map"));
  const lines = code.split("\n");

  await SourceMapConsumer.with(map, null, (c) => {
    // THE case: the call `helper(21)` in the bundle comes from main.ts line 2,
    // at the column where `helper` really sits.
    const gl = lines.findIndex((l) => l.includes("answer = helper"));
    const gc = lines[gl].indexOf("helper");
    const o = c.originalPositionFor({ line: gl + 1, column: gc });
    assert.equal(o.source, "../src/main.ts");
    assert.equal(o.line, 2);
    const srcLine = map.sourcesContent[map.sources.indexOf(o.source)].split("\n")[o.line - 1];
    assert.equal(srcLine.slice(o.column, o.column + 6), "helper");

    // And the hoisted module: `const helper = …` comes from dep.ts, where the
    // declaration starts AFTER `export ` — column 7, not 0.
    const dl = lines.findIndex((l) => l.startsWith("const helper"));
    const d = c.originalPositionFor({ line: dl + 1, column: 0 });
    assert.equal(d.source, "../src/dep.ts");
    assert.equal(d.line, 1);
    assert.equal(d.column, 7);
  });
});

test("sourcemap: the module HEADERS do not shift the mappings under them", async () => {
  const dir = mapProject("true");
  assert.equal(build(dir).status, 0);
  const code = read(dir, "dist", "main.js");
  const map = JSON.parse(read(dir, "dist", "main.js.map"));
  const lines = code.split("\n");
  await SourceMapConsumer.with(map, null, (c) => {
    // The banner and the `// ── dep.ts ──` headers sit above real code, and the
    // banner contains an em dash and box-drawing characters — three bytes each
    // for one column. Every statement below them must still resolve.
    for (const [i, l] of lines.entries()) {
      if (!/^(const|console)/.test(l)) continue;
      const o = c.originalPositionFor({ line: i + 1, column: 0 });
      assert.ok(o.source, `bundle L${i + 1} maps to nothing: ${l}`);
      assert.ok(o.line >= 1);
    }
  });
});

test("sourcemap: a RENAMED binding still points at its original identifier", async () => {
  const dir = tmpProject({
    "a.js": `export const shared = () => "a";`,
    "b.js": `export const shared = () => "b";`,
    "main.js":
      `import { shared as fromA } from './a.js';\n` +
      `import { shared as fromB } from './b.js';\n` +
      `console.log(fromA(), fromB());\n`,
    "zbundle.config.ts": `export default { input: "main.js", sourcemap: true };`,
  });
  assert.equal(build(dir).status, 0);
  const code = read(dir, "dist", "main.js");
  const map = JSON.parse(read(dir, "dist", "main.js.map"));
  // One of the two collided and became `shared$1` — the bundle renamed it.
  assert.match(code, /shared\$1/);
  const lines = code.split("\n");
  await SourceMapConsumer.with(map, null, (c) => {
    const gl = lines.findIndex((l) => l.includes("shared$1 ="));
    const o = c.originalPositionFor({ line: gl + 1, column: lines[gl].indexOf("shared$1") });
    // Renaming replaces the TEXT of a node, never its span: the position still
    // points at the `shared` that was written in the source.
    const srcLine = map.sourcesContent[map.sources.indexOf(o.source)].split("\n")[o.line - 1];
    assert.match(srcLine.slice(o.column), /^shared/);
  });
});

test("sourcemap: two runs produce byte-identical maps (determinism)", () => {
  const a = mapProject("true");
  const b = mapProject("true");
  assert.equal(build(a).status, 0);
  assert.equal(build(b).status, 0);
  assert.equal(read(a, "dist", "main.js.map"), read(b, "dist", "main.js.map"));
});

test("sourcemap: an unknown mode is refused", () => {
  const dir = mapProject(`"linked"`);
  const r = build(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /sourcemap: expected boolean \| "inline" \| "hidden"/);
});

test("sourcemap: it is no longer a RESERVED option", () => {
  const dir = mapProject("true");
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  // The refusal left in the same release that delivered the feature.
  assert.doesNotMatch(r.stderr, /reserved/);
});

test("CLI: --sourcemap overrides the config, and names an unknown mode", () => {
  const dir = mapProject("false");
  assert.equal(build(dir, ["--sourcemap"]).status, 0);
  assert.ok(exists(dir, "dist", "main.js.map"));

  assert.equal(build(dir, ["--sourcemap=hidden"]).status, 0);
  assert.doesNotMatch(read(dir, "dist", "main.js"), /sourceMappingURL/);

  const bad = build(dir, ["--sourcemap=linked"]);
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /unknown mode "linked"/);
});

// ---- names: what a debugger shows for a renamed binding (0.4.1) ----

test("sourcemap: a MINIFIED name resolves to the original identifier", async () => {
  const dir = tmpProject({
    "dep.js": `export const helperWithLongName = (n) => n * 2;`,
    "main.js": `import { helperWithLongName } from './dep.js';\nconsole.log(helperWithLongName(21));`,
    "zbundle.config.ts": `export default { input: "main.js", minify: true, sourcemap: true };`,
  });
  assert.equal(build(dir).status, 0);
  const code = read(dir, "dist", "main.js");
  const map = JSON.parse(read(dir, "dist", "main.js.map"));
  // The bundle says `a`; without `names` a debugger could only say `a` too.
  assert.doesNotMatch(code, /helperWithLongName/);
  assert.ok(map.names.includes("helperWithLongName"), JSON.stringify(map.names));

  const lines = code.split("\n");
  await SourceMapConsumer.with(map, null, (c) => {
    let checked = 0;
    for (const [i, l] of lines.entries()) {
      if (l.trimStart().startsWith("//")) continue;
      for (const m of l.matchAll(/\ba\b/g)) {
        const o = c.originalPositionFor({ line: i + 1, column: m.index });
        assert.equal(o.name, "helperWithLongName", `L${i + 1}C${m.index}`);
        checked++;
      }
    }
    // The declaration AND the call site — one of them losing its name is
    // exactly the gap nobody notices.
    assert.ok(checked >= 2, `only ${checked} occurrence(s) checked`);
  });
});

test("sourcemap: an UNCHANGED identifier carries no name (nothing to say)", () => {
  const dir = tmpProject({
    "main.js": `const kept = 1;\nconsole.log(kept);`,
    "zbundle.config.ts": `export default { input: "main.js", sourcemap: true };`,
  });
  assert.equal(build(dir).status, 0);
  const map = JSON.parse(read(dir, "dist", "main.js.map"));
  // Nothing was renamed, so the debugger reads the source: a `names` entry would
  // be dead weight in every bundle that does not minify.
  assert.deepEqual(map.names, []);
});

test("sourcemap: the name is the identifier AT THAT SOURCE POSITION", async () => {
  const dir = tmpProject({
    "left.js": `export const shared = () => "L";`,
    "right.js": `export const shared = () => "R";`,
    "main.js":
      `import { shared as fromLeft } from './left.js';\n` +
      `import { shared as fromRight } from './right.js';\n` +
      `console.log(fromLeft(), fromRight());`,
    "zbundle.config.ts": `export default { input: "main.js", sourcemap: true };`,
  });
  assert.equal(build(dir).status, 0);
  const code = read(dir, "dist", "main.js");
  const map = JSON.parse(read(dir, "dist", "main.js.map"));
  const lines = code.split("\n");
  await SourceMapConsumer.with(map, null, (c) => {
    // A reference inside main.js was written as `fromLeft` there — that is what
    // a developer reading main.js should be shown, not the exporter's name.
    const gl = lines.findIndex((l) => l.startsWith("console.log"));
    const o = c.originalPositionFor({ line: gl + 1, column: lines[gl].indexOf("(") + 1 });
    assert.equal(o.source, "../main.js");
    assert.ok(["fromLeft", "fromRight"].includes(o.name), `got ${o.name}`);
  });
});

test("sourcemap: names survive determinism (two runs, identical maps)", () => {
  const files = {
    "dep.js": `export const longEnoughToBeRenamed = () => 1;`,
    "main.js": `import { longEnoughToBeRenamed } from './dep.js';\nconsole.log(longEnoughToBeRenamed());`,
    "zbundle.config.ts": `export default { input: "main.js", minify: true, sourcemap: true };`,
  };
  const a = tmpProject(files);
  const b = tmpProject(files);
  assert.equal(build(a).status, 0);
  assert.equal(build(b).status, 0);
  assert.equal(read(a, "dist", "main.js.map"), read(b, "dist", "main.js.map"));
});

// ---- paths: where `sources` points, on any platform (0.4.2) ----

const { sourceEntry } = require("./dist/sourcemap.js");

/** A project whose sources sit one level below the config. */
function pathProject(sourcemap) {
  return tmpProject({
    "src/deep/dep.js": `export const v = 1;`,
    "src/main.js": `import { v } from './deep/dep.js';\nconsole.log(v);`,
    "zbundle.config.ts": `export default { input: "src/main.js", sourcemap: ${sourcemap} };`,
  });
}
const readMap = (dir, ...rel) => JSON.parse(read(dir, ...rel));

test("sourcemap: sources are relative to the MAP, whatever output.dir is", () => {
  const flat = pathProject("true");
  assert.equal(build(flat).status, 0);
  assert.deepEqual(readMap(flat, "dist", "main.js.map").sources.sort(), [
    "../src/deep/dep.js",
    "../src/main.js",
  ]);

  // One level deeper: every entry gains exactly one `..`. Resolving against the
  // cwd instead would leave these unchanged, which is the classic bug.
  const nested = tmpProject({
    "src/deep/dep.js": `export const v = 1;`,
    "src/main.js": `import { v } from './deep/dep.js';\nconsole.log(v);`,
    "zbundle.config.ts": `export default {
      input: "src/main.js", sourcemap: true, output: { dir: "build/js" },
    };`,
  });
  assert.equal(build(nested).status, 0);
  assert.deepEqual(readMap(nested, "build", "js", "main.js.map").sources.sort(), [
    "../../src/deep/dep.js",
    "../../src/main.js",
  ]);
});

test("sourcemap: sources always use forward slashes", () => {
  const dir = pathProject("true");
  assert.equal(build(dir).status, 0);
  for (const s of readMap(dir, "dist", "main.js.map").sources) {
    // A `\` in a sources entry reads as an escape, not a directory: a bundle
    // built on Windows has to open on Linux.
    assert.doesNotMatch(s, /\\/, s);
  }
});

test("sourcemap: sourceRoot is emitted only when asked", () => {
  const without = pathProject("true");
  assert.equal(build(without).status, 0);
  // Absent, not empty: "no sourceRoot" and `sourceRoot: ""` are different
  // statements, and some consumers treat them differently.
  assert.ok(!("sourceRoot" in readMap(without, "dist", "main.js.map")));

  const with_ = pathProject(`{ sourceRoot: "/@src/" }`);
  assert.equal(build(with_).status, 0);
  assert.equal(readMap(with_, "dist", "main.js.map").sourceRoot, "/@src/");
});

test("sourcemap: sourcesContent can be turned off", () => {
  const on = pathProject("true");
  const off = pathProject(`{ sourcesContent: false }`);
  assert.equal(build(on).status, 0);
  assert.equal(build(off).status, 0);
  assert.equal(readMap(on, "dist", "main.js.map").sourcesContent.length, 2);
  assert.ok(!("sourcesContent" in readMap(off, "dist", "main.js.map")));
  // A much smaller map, for setups that serve the sources themselves.
  assert.ok(read(off, "dist", "main.js.map").length < read(on, "dist", "main.js.map").length);
});

test("sourcemap: the object form implies a map, and mode still chooses how", () => {
  const implied = pathProject(`{ sourceRoot: "x/" }`);
  assert.equal(build(implied).status, 0);
  // Writing the object at all means you want one.
  assert.ok(exists(implied, "dist", "main.js.map"));
  assert.match(read(implied, "dist", "main.js"), /sourceMappingURL/);

  const hidden = pathProject(`{ mode: "hidden", sourceRoot: "x/" }`);
  assert.equal(build(hidden).status, 0);
  assert.ok(exists(hidden, "dist", "main.js.map"));
  assert.doesNotMatch(read(hidden, "dist", "main.js"), /sourceMappingURL/);

  const off = pathProject(`{ mode: false }`);
  assert.equal(build(off).status, 0);
  assert.ok(!exists(off, "dist", "main.js.map"));
});

test("sourcemap: a bad sourcemap object is refused by key and by type", () => {
  const badMode = pathProject(`{ mode: "linked" }`);
  assert.match(build(badMode).stderr, /sourcemap\.mode: expected boolean \| "inline" \| "hidden"/);

  const badRoot = pathProject(`{ sourceRoot: 3 }`);
  assert.match(build(badRoot).stderr, /sourcemap\.sourceRoot: expected string/);

  const typo = pathProject(`{ sourceRot: "x" }`);
  const r = build(typo);
  assert.equal(r.status, 0, r.stderr); // an unknown key never stops the build
  assert.match(r.stderr, /unknown option sourcemap\.sourceRot — did you mean sourcemap\.sourceRoot\?/);
});

test("sourceEntry: a Windows path is normalised, and another drive falls back to file://", () => {
  // `sourceEntry` takes its path primitives as arguments precisely so the
  // Windows behaviour can be exercised from any platform — the CI's Windows job
  // is a smoke test, not the whole battery.
  const winAbs = (p) => /^[A-Za-z]:/.test(p) || p.startsWith("\\");
  const toUrl = (p) => `file:///${p.replace(/\\/g, "/")}`;

  // Same drive: a relative path, with backslashes turned into slashes.
  assert.equal(
    sourceEntry("C:\\proj\\dist", "C:\\proj\\src\\a.ts", () => "..\\src\\a.ts", winAbs, "\\", toUrl),
    "../src/a.ts",
  );
  // Another drive: `path.relative` cannot express it, so an absolute URL is the
  // only honest answer — an absolute Windows path is not a valid sources entry.
  assert.equal(
    sourceEntry("C:\\proj\\dist", "D:\\other\\x.ts", () => "D:\\other\\x.ts", winAbs, "\\", toUrl),
    "file:///D:/other/x.ts",
  );
  // POSIX, unchanged.
  assert.equal(
    sourceEntry("/p/dist", "/p/src/a.ts", () => "../src/a.ts", (p) => p.startsWith("/"), "/", toUrl),
    "../src/a.ts",
  );
});
