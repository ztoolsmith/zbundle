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
  assert.equal(zbundle.VERSION, "0.1.0");
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
  assert.equal(zbundle.VERSION, "0.1.0");
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
