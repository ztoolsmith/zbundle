// Tests Node (`node --test`) via l'addon : la surface JS réelle, celle que
// verra un utilisateur. Les tests Zig (`zig build test`) couvrent l'intérieur ;
// ici on vérifie la traversée de la frontière N-API et les cas OBLIGATOIRES de
// la v0.1.
//
// Les fixtures de `corpus/fixtures/` servent de données : une seule source de
// vérité entre le harnais corpus et ces tests.
const test = require("node:test");
const assert = require("node:assert");
const path = require("node:path");
const fs = require("node:fs");
const zbundle = require("./index.js");

const FIXTURES = path.join(__dirname, "..", "..", "corpus", "fixtures");
const REAL = path.join(__dirname, "..", "..", "corpus", "real");
const fixture = (name, file) => path.join(FIXTURES, name, file);

/** Les chemins des modules, relatifs à la fixture, triés. */
const modulesOf = (g, root) =>
  g.modules.map((m) => path.relative(root, m.path).split(path.sep).join("/")).sort();

/** Le module d'un id, en relatif. */
const at = (g, root, id) => path.relative(root, g.modules[id].path).split(path.sep).join("/");

// ---- le resolver seul ----

test("resolver : la table d'extensions, cas par cas", () => {
  const dir = path.join(FIXTURES, "omitted-ext");
  // Chaque `pick-*` a DEUX fichiers candidats ; l'ordre .ts > .tsx > .js > .jsx > .mjs décide.
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
    assert.equal(path.basename(r.path), want, `${specifier} doit résoudre ${want}`);
  }
});

test("resolver : './x' résout x.ts AVANT x.js", () => {
  const dir = path.join(FIXTURES, "omitted-ext");
  // Le contrôle négatif : les deux fichiers existent bien.
  assert.ok(fs.existsSync(path.join(dir, "pick-ts.ts")));
  assert.ok(fs.existsSync(path.join(dir, "pick-ts.js")));
  assert.equal(path.basename(zbundle.resolve(dir, "./pick-ts").path), "pick-ts.ts");
});

test("resolver : './dir' -> dir/index.ts (et index.ts gagne sur index.js)", () => {
  const dir = path.join(FIXTURES, "index-resolution");
  assert.equal(zbundle.resolve(dir, "./utils").path.endsWith(path.join("utils", "index.ts")), true);
  // widgets/ contient index.js ET index.ts : la source doit gagner.
  assert.equal(zbundle.resolve(dir, "./widgets").path.endsWith(path.join("widgets", "index.ts")), true);
});

test("resolver : extension explicite prise telle quelle", () => {
  const dir = path.join(FIXTURES, "omitted-ext");
  assert.equal(path.basename(zbundle.resolve(dir, "./pick-ts.js").path), "pick-ts.js");
});

test("resolver : specifier nu -> external, jamais une erreur", () => {
  const dir = path.join(FIXTURES, "externals");
  for (const spec of ["react", "@scope/ui", "lodash/debounce", "node:fs/promises"]) {
    const r = zbundle.resolve(dir, spec);
    assert.equal(r.kind, "external");
    assert.equal(r.path, spec);
  }
});

test("resolver : chemin canonique (les '..' n'ouvrent pas deux modules)", () => {
  const dir = path.join(FIXTURES, "chain");
  const direct = zbundle.resolve(dir, "./b.js").path;
  const detour = zbundle.resolve(dir, "./../chain/./b.js").path;
  assert.equal(direct, detour);
  assert.ok(path.isAbsolute(direct));
});

test("resolver : introuvable -> erreur avec les chemins essayés", () => {
  const dir = path.join(FIXTURES, "chain");
  assert.throws(
    () => zbundle.resolve(dir, "./missing"),
    (err) => {
      assert.match(err.message, /cannot resolve '\.\/missing'/);
      assert.match(err.message, /tried:/);
      // Les 5 extensions PUIS les 5 index.<ext>, dans l'ordre de la table.
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

// ---- le graphe ----

test("graphe : chaîne simple a -> b -> c", () => {
  const root = path.join(FIXTURES, "chain");
  const g = zbundle.graph(fixture("chain", "entry.js"));
  assert.deepEqual(modulesOf(g, root), ["b.js", "c.js", "entry.js"]);
  assert.equal(g.stats.edges, 2);
  assert.equal(at(g, root, g.entry), "entry.js");
});

test("graphe : le diamant fait 4 modules, pas 5 (déduplication)", () => {
  const root = path.join(FIXTURES, "diamond");
  const g = zbundle.graph(fixture("diamond", "entry.js"));
  assert.equal(g.stats.modules, 4);
  assert.equal(g.stats.edges, 4); // les DEUX arêtes vers d existent
  const d = g.modules.find((m) => m.path.endsWith("d.js")).id;
  assert.equal(g.edges.filter((e) => e.to === d).length, 2);
  assert.equal(g.stats.cycles, 0);
});

test("graphe : le cycle est détecté, listé, et n'est PAS une erreur", () => {
  const root = path.join(FIXTURES, "cycle");
  const g = zbundle.graph(fixture("cycle", "entry.js")); // ne throw pas
  assert.equal(g.stats.modules, 2);
  assert.equal(g.stats.cycles, 1);
  assert.deepEqual(
    g.cycles[0].map((id) => at(g, root, id)).sort(),
    ["b.js", "entry.js"],
  );
});

test("graphe : un cycle ne fait pas boucler (le run se termine)", () => {
  // Le vrai test de la boucle infinie : ce test rend la main.
  const g = zbundle.graph(fixture("cycle", "entry.js"));
  assert.ok(g.stats.build_ms >= 0);
});

test("graphe : 'react' devient external et le graphe CONTINUE", () => {
  const root = path.join(FIXTURES, "externals");
  const g = zbundle.graph(fixture("externals", "entry.js"));
  assert.deepEqual(modulesOf(g, root), ["entry.js", "local.js"]); // le graphe a continué
  assert.equal(g.stats.externals, 5);
  const react = g.externals.find((e) => e.specifier === "react");
  assert.equal(react.count, 2); // dédupliqué, mais compté deux fois
  const edge = g.edges.find((e) => e.specifier === "react");
  assert.equal(edge.to, null);
  assert.equal(g.externals[edge.external].specifier, "react");
});

test("graphe : './missing' -> erreur avec le demandeur et les chemins essayés", () => {
  const dir = path.join(FIXTURES, "chain");
  const entry = path.join(dir, "broken-entry.js");
  fs.writeFileSync(entry, "import './b.js';\nimport './missing';\n");
  try {
    assert.throws(
      () => zbundle.graph(entry),
      (err) => {
        assert.match(err.message, /cannot resolve '\.\/missing'/);
        assert.match(err.message, /from .*broken-entry\.js/); // le demandeur
        assert.match(err.message, /tried:/);
        assert.match(err.message, /missing\.ts/);
        return true;
      },
    );
  } finally {
    fs.unlinkSync(entry);
  }
});

test("graphe : une entry .tsx (JSX + types) parse et ses imports sortent", () => {
  const root = path.join(FIXTURES, "mixed-ext");
  const g = zbundle.graph(fixture("mixed-ext", "entry.tsx"));
  assert.equal(g.stats.parse_errors, 0); // le JSX et les types n'ont rien cassé
  assert.equal(g.modules[g.entry].format, "tsx");
  assert.deepEqual(modulesOf(g, root), ["data.ts", "entry.tsx", "format.js", "row.jsx"]);
  // Chaque fichier a été parsé dans SON mode.
  const fmt = Object.fromEntries(g.modules.map((m) => [path.basename(m.path), m.format]));
  assert.deepEqual(fmt, {
    "entry.tsx": "tsx",
    "row.jsx": "jsx",
    "data.ts": "ts",
    "format.js": "js",
  });
});

test("graphe : `export { a } from './b'` EST une dépendance", () => {
  const root = path.join(FIXTURES, "re-exports");
  const g = zbundle.graph(fixture("re-exports", "entry.js"));
  const edge = g.edges.find((e) => e.specifier === "./y.js");
  assert.ok(edge, "l'arête du re-export doit exister");
  assert.equal(edge.kind, "re_export");
  assert.equal(at(g, root, edge.to), "y.js");
});

test("graphe : `export * from` est une dépendance, transitive", () => {
  const root = path.join(FIXTURES, "export-star");
  const g = zbundle.graph(fixture("export-star", "entry.js"));
  assert.deepEqual(modulesOf(g, root), ["a.js", "b.js", "deep.js", "entry.js"]);
  assert.equal(g.edges.find((e) => e.specifier === "./a.js").kind, "export_all");
});

test("graphe : import() est suivi ET marqué is_dynamic", () => {
  const g = zbundle.graph(fixture("dynamic-import", "entry.js"));
  const lazy = g.edges.find((e) => e.specifier === "./lazy.js");
  assert.equal(lazy.kind, "dynamic_import");
  assert.equal(lazy.is_dynamic, true);
  // Un import() statique reste non-dynamique.
  assert.equal(g.edges.find((e) => e.specifier === "./eager.js").is_dynamic, false);
  // `import(variable)` n'est pas analysable : aucune arête, aucune erreur.
  assert.equal(g.edges.length, 6);
});

test("graphe : `import type` n'est PAS une arête (effacé à l'émission)", () => {
  const dir = path.join(FIXTURES, "chain");
  const entry = path.join(dir, "type-only-entry.ts");
  const types = path.join(dir, "type-only-types.ts");
  fs.writeFileSync(types, "export type T = string;\n");
  fs.writeFileSync(entry, "import type { T } from './type-only-types';\nimport './b.js';\nexport const x: T = 'x';\n");
  try {
    const g = zbundle.graph(entry);
    assert.equal(g.stats.modules, 3); // entry + b + c, PAS types
    assert.ok(!g.modules.some((m) => m.path.includes("type-only-types")));
  } finally {
    fs.unlinkSync(entry);
    fs.unlinkSync(types);
  }
});

test("graphe : du code cassé n'arrête pas la construction (error recovery)", () => {
  const dir = path.join(FIXTURES, "chain");
  const entry = path.join(dir, "recovery-entry.js");
  fs.writeFileSync(entry, "import './b.js';\nlet oops = ;\nimport './c.js';\n");
  try {
    const g = zbundle.graph(entry);
    assert.equal(g.stats.modules, 3); // les deux imports sains sont là
    assert.ok(g.stats.parse_errors > 0); // et l'erreur est signalée, pas cachée
    assert.ok(g.modules.find((m) => m.path.endsWith("recovery-entry.js")).parse_errors > 0);
  } finally {
    fs.unlinkSync(entry);
  }
});

// ---- graphPrint ----

test("graphPrint : arbre indenté, externals et cycles marqués", () => {
  const out = zbundle.graphPrint(fixture("cycle", "entry.js"));
  assert.match(out, /\.\/entry\.js/);
  assert.match(out, /\(cycle\)/);
  assert.match(out, /cycles:/);
  assert.match(out, /2 modules, 2 edges/);
});

test("graphPrint : les externals et les import() dynamiques se voient", () => {
  const out = zbundle.graphPrint(fixture("dynamic-import", "entry.js"));
  assert.match(out, /some-vendor {2}\(external, dynamic\)/);
  assert.match(out, /\(dynamic\)/);
});

// ---- le vrai projet ----

test("vrai projet : lodash-es se construit, stats plausibles, zéro crash", (t) => {
  const entry = path.join(REAL, "node_modules", "lodash-es", "lodash.js");
  if (!fs.existsSync(entry)) return t.skip("corpus/real non installé (npm install dans corpus/real/)");
  const g = zbundle.graph(entry);
  // Pas d'oracle : on vérifie des ordres de grandeur et des invariants.
  assert.ok(g.stats.modules > 500, `${g.stats.modules} modules`);
  assert.ok(g.stats.edges > g.stats.modules, "un vrai graphe a plus d'arêtes que de modules");
  assert.equal(g.stats.parse_errors, 0, "zéro erreur de parse sur du vrai code");
  assert.equal(g.modules.length, new Set(g.modules.map((m) => m.path)).size, "aucun chemin en double");
  // Toute arête pointe vers un module OU un external, jamais les deux ni aucun.
  for (const e of g.edges) {
    assert.ok((e.to === null) !== (e.external === null), "une arête a exactement une cible");
    if (e.to !== null) assert.ok(e.to < g.modules.length);
  }
  console.log(`      lodash-es : ${g.stats.modules} modules, ${g.stats.edges} arêtes, ${g.stats.build_ms.toFixed(0)} ms`);
});

// ---- la surface ----

test("VERSION est exposée et correspond au package.json", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, "package.json"), "utf8"));
  assert.equal(zbundle.VERSION, pkg.version);
});

// ---- Les deux capacités venues de zcompiler 0.2.0 ----
// Ces fixtures sont exactement les deux trous que zbundle avait révélés : avant
// la 0.2.0, ces fichiers ne parsaient pas et AUCUNE dépendance n'en sortait.

test("export * as ns : arête de kind export_all_as, avec le nom d'export", () => {
  const root = path.join(FIXTURES, "export-star-as");
  const g = zbundle.graph(fixture("export-star-as", "entry.js"));
  assert.equal(g.stats.parse_errors, 0);

  const math = g.edges.find((e) => e.specifier === "./math.js");
  assert.equal(math.kind, "export_all_as");
  assert.equal(math.name, "math"); // le nom d'export voyage jusqu'ici
  assert.equal(at(g, root, math.to), "math.js");

  // `export * from` (nu) reste un kind DIFFÉRENT : ce n'est pas la même opération.
  assert.equal(g.edges.find((e) => e.specifier === "./shared.js").kind, "export_all");
  assert.equal(g.edges.find((e) => e.specifier === "./shared.js").name, null);
  // Et `export { x } from` reste un re_export.
  assert.equal(g.edges.find((e) => e.specifier === "./plain.js").kind, "re_export");

  // La dépendance est suivie TRANSITIVEMENT (strings.js -> pad.js).
  assert.deepEqual(modulesOf(g, root), [
    "entry.js", "math.js", "pad.js", "plain.js", "shared.js", "strings.js",
  ].sort());
});

test("import attributes : le fichier parse et ses attributs arrivent jusqu'au graphe", () => {
  const root = path.join(FIXTURES, "json-import");
  const g = zbundle.graph(fixture("json-import", "entry.js"));
  // LE point : zéro erreur de parse. Avant zcompiler 0.2.0, l'entry entier
  // partait en erreur de syntaxe et même './code.js' disparaissait du graphe.
  assert.equal(g.stats.parse_errors, 0);
  assert.deepEqual(modulesOf(g, root), ["code.js", "entry.js", "helper.js"]);

  const cfg = g.edges.find((e) => e.specifier === "@app/config/data.json");
  assert.deepEqual(cfg.attributes, [{ key: "type", value: "json" }]);
  assert.equal(g.edges.find((e) => e.specifier === "normalize.css/normalize.css").attributes[0].value, "css");
  // `assert { … }` (déprécié) donne les MÊMES attributs — c'est de la syntaxe.
  const legacy = g.edges.find((e) => e.specifier === "vendor-legacy");
  assert.equal(legacy.kind, "export_all_as");
  assert.deepEqual(legacy.attributes, [{ key: "type", value: "json" }]);
  // Sans clause : tableau vide, rien à gérer côté consommateur.
  assert.deepEqual(g.edges.find((e) => e.specifier === "./code.js").attributes, []);
});

test("import attributes : un '.json' RELATIF ne résout toujours pas (v0.1)", () => {
  // La frontière honnête : zcompiler sait lire la syntaxe, mais la table de
  // résolution de zbundle s'arrête aux extensions JS/TS. Les loaders d'assets
  // sont la v0.5 — et l'erreur le dit clairement.
  const dir = path.join(FIXTURES, "json-import");
  assert.throws(
    () => zbundle.resolve(dir, "./data.json"),
    (err) => {
      assert.match(err.message, /cannot resolve '\.\/data\.json'/);
      assert.match(err.message, /data\.json\.ts/); // les chemins essayés
      return true;
    },
  );
});

// ══════════════════ v0.2 : LE BUNDLE ══════════════════
// Le juge suprême (le bundle s'exécute et dit la même chose que l'original)
// vit dans playground/run.mjs. Ici : la surface JS et les invariants du linking.

const PROJECTS = path.join(__dirname, "..", "..", "playground", "projects");
const project = (name) => path.join(PROJECTS, name, "main.js");

test("bundle : un seul fichier, du JS que zcompiler reparse sans erreur", () => {
  const code = zbundle.bundle(project("diamond"));
  assert.equal(typeof code, "string");
  assert.ok(code.length > 0);
  // Aucun `import` relatif ne survit : tout est fusionné.
  assert.doesNotMatch(code, /from ['"]\.\.?\//);
});

test("bundle : le module partagé du diamant n'est émis QU'UNE fois", () => {
  const code = zbundle.bundle(project("diamond"));
  assert.equal(code.split("export const base = 10").length - 1, 0); // `export ` retiré
  assert.equal(code.split("const base = 10").length - 1, 1);
});

test("bundle : ordre topologique — les dépendances avant les dépendants", () => {
  const code = zbundle.bundle(project("diamond"));
  const shared = code.indexOf("const base = 10");
  const b = code.indexOf("const fromB");
  const main = code.indexOf("console.log('b:'");
  assert.ok(shared >= 0 && b >= 0 && main >= 0);
  assert.ok(shared < b, "shared avant b");
  assert.ok(b < main, "b avant main");
});

test("bundle : les collisions sont renommées, les noms libres préservés", () => {
  const { code, stats } = zbundle.bundleStats(project("barrel"));
  // Trois `helper` distincts dans trois modules.
  assert.match(code, /const helper = /);
  assert.match(code, /const helper\$1 = /);
  assert.match(code, /const helper\$2 = /);
  assert.ok(stats.renamed >= 2);
  // Un nom sans collision garde le sien : le bundle reste lisible.
  assert.match(code, /const VERSION = '1\.2\.3'/);
});

test("bundle : un namespace est matérialisé en objet", () => {
  const code = zbundle.bundle(project("barrel"));
  assert.match(code, /const strings_ns = \{/);
  assert.match(code, /strings_ns\.upper\(/);
});

test("bundle : les externals sont hoistés en tête et dédupliqués", () => {
  const code = zbundle.bundle(project("external"));
  // `node:path` est importé par DEUX modules -> une seule ligne.
  assert.equal(code.split("from 'node:path'").length - 1, 1);
  assert.match(code, /^import .* from 'node:path';$/m);
  // Et avant le premier module.
  assert.ok(code.indexOf("node:path") < code.indexOf("── "));
});

test("bundle : seuls les exports de l'ENTRY survivent", () => {
  const code = zbundle.bundle(project("barrel"));
  // main.js n'exporte rien -> aucun `export` dans le bundle.
  assert.doesNotMatch(code, /^export /m);
});

test("bundleStats : des mesures cohérentes", () => {
  const { code, stats } = zbundle.bundleStats(project("barrel"));
  assert.equal(stats.output_bytes, Buffer.byteLength(code));
  // Depuis la v0.3, `modules` compte les modules ÉMIS : le barrel pur
  // (`lib/index.js`, que des re-exports) est éliminé, d'où 5 et non 6.
  assert.equal(stats.modules + stats.modules_dropped, 6);
  assert.ok(stats.modules >= 4);
  assert.ok(stats.input_bytes > 0);
  assert.ok(stats.bundle_ms >= 0);
});

test("bundlePrint : les stats en tête, le bundle en dessous", () => {
  const out = zbundle.bundlePrint(project("diamond"));
  assert.match(out, /^\/\/ \d+ modules emis \(\d+ elimines\)/);
  assert.match(out, /tree-shaking : \d+ statements gardes, \d+ elimines/);
  assert.match(out, /octets/);
  assert.match(out, /── /); // les en-têtes de module
});

test("bundle : un en-tête par module, pour lire le bundle à l'œil", () => {
  const code = zbundle.bundle(project("diamond"));
  for (const f of ["shared.js", "b.js", "c.js", "main.js"]) {
    assert.ok(code.includes(`── ${f} ──`), `en-tête manquant pour ${f}`);
  }
});

// ---- les refus : une erreur CLAIRE, jamais un bundle faux ----

const refusal = (name) => path.join(__dirname, "..", "..", "playground", "refusals", name, "main.js");

test("refus : top-level await", () => {
  assert.throws(() => zbundle.bundle(refusal("top-level-await")), /top-level await/);
});

test("refus : import.meta", () => {
  assert.throws(() => zbundle.bundle(refusal("import-meta")), /import\.meta/);
});

test("refus : import() dynamique vers un module interne", () => {
  assert.throws(
    () => zbundle.bundle(refusal("dynamic-internal")),
    (err) => {
      assert.match(err.message, /import\(\) dynamique/);
      assert.match(err.message, /code-splitting/); // dit ce qui viendra
      return true;
    },
  );
});

test("refus : live binding exposé via un objet namespace", () => {
  assert.throws(
    () => zbundle.bundle(refusal("namespace-live")),
    (err) => {
      assert.match(err.message, /objet namespace/);
      assert.match(err.message, /Importez le nom directement/); // dit quoi faire
      return true;
    },
  );
});

test("live binding importé NOMMÉMENT : accepté (le hoisting le gère)", () => {
  // Le pendant du refus : sans namespace, la réassignation reste visible parce
  // qu'après fusion c'est LA MÊME variable. Vérifié par run.mjs à l'exécution.
  const code = zbundle.bundle(project("live-binding"));
  assert.match(code, /let count = 0/);
});

test("VERSION suit le package.json — 1re version publiee", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, "package.json"), "utf8"));
  assert.equal(zbundle.VERSION, pkg.version);
  assert.equal(zbundle.VERSION, "0.1.0");
});

// ══════════════════ v0.3 : LE TREE-SHAKING ══════════════════
// Le juge (le bundle s'exécute et dit la même chose) reste playground/run.mjs,
// qui vérifie EN PLUS l'absence textuelle du code mort. Ici : la surface JS.

test("shaking : importer 1 nom sur 20 n'emporte pas les 19 autres", () => {
  const { code, stats } = zbundle.bundleStats(project("shake-barrel"));
  assert.match(code, /keptOne/);
  for (const dead of ["unused2", "unused7", "unused19", "helperOfUnused"]) {
    assert.doesNotMatch(code, new RegExp(dead), `${dead} aurait dû disparaître`);
  }
  // Le barrel de 24 modules se réduit à une poignée.
  assert.ok(stats.modules <= 4, `${stats.modules} modules émis`);
  assert.ok(stats.modules_dropped >= 20);
  assert.ok(stats.output_bytes < stats.input_bytes / 5, "le bundle doit fondre");
});

test("shaking : un effet de bord top-level survit sans être importé", () => {
  const code = zbundle.bundle(project("shake-sideeffect"));
  assert.match(code, /__PATCHED__/);
  assert.match(code, /registry\.push/);
  // …mais la fonction pure et inutilisée du même module meurt.
  assert.doesNotMatch(code, /neverUsedHelper/);
});

test("shaking : le piège du getter — un accès membre est conservé", () => {
  const code = zbundle.bundle(project("shake-getter"));
  // `source.value` peut déclencher un getter : le supprimer changerait le
  // comportement observable. Conservateur = correct.
  assert.match(code, /config/);
  assert.match(code, /get value/);
});

test("shaking : classe pure inutilisée éliminée, classe impure conservée", () => {
  const code = zbundle.bundle(project("shake-class"));
  assert.doesNotMatch(code, /NeverUsed/);
  // Le champ statique APPELLE : la classe s'enregistre à sa définition.
  assert.match(code, /RegistersItself/);
});

test("shaking : export * partiellement consommé ne tire que ce qui sert", () => {
  const code = zbundle.bundle(project("shake-star"));
  assert.match(code, /fromA/);
  assert.doesNotMatch(code, /fromB/);
  assert.doesNotMatch(code, /fromC/);
  assert.doesNotMatch(code, /unusedFromA/);
});

test("shaking : un module entièrement mort disparaît, en-tête comprise", () => {
  const code = zbundle.bundle(project("shake-diamond"));
  assert.doesNotMatch(code, /heavy\.js/); // même le commentaire d'en-tête
  assert.doesNotMatch(code, /heavyDependency/);
  assert.match(code, /sharedUtil/); // partagé avec la branche vivante
});

test("bundleReport : ce qui est mort, où, et pourquoi", () => {
  const { dead } = zbundle.bundleReport(project("shake-diamond"));
  assert.ok(dead.length > 0);
  for (const d of dead) {
    assert.equal(typeof d.module, "string");
    assert.ok(d.line >= 1);
    assert.ok(d.snippet.length > 0);
    assert.ok(d.reason.length > 0);
  }
  const heavy = dead.find((d) => d.module.includes("heavy.js"));
  assert.ok(heavy, "heavy.js doit figurer parmi les éliminations");
  assert.match(heavy.reason, /module entierement elimine/);
});

test("les stats de shaking sont cohérentes", () => {
  const { stats } = zbundle.bundleStats(project("shake-barrel"));
  assert.ok(stats.statements_kept > 0);
  assert.ok(stats.statements_dropped > stats.statements_kept);
  assert.equal(typeof stats.modules_dropped, "number");
});

test("non-régression : les projets v0.2 gardent leur comportement", () => {
  // Le diamant : le module partagé reste émis UNE fois, et le compteur d'effet
  // de bord (impur) survit — c'est ce qui prouve qu'on n'a pas trop shaké.
  const code = zbundle.bundle(project("diamond"));
  assert.equal(code.split("counter.times += 1").length - 1, 1);
  assert.equal(code.split("const base = 10").length - 1, 1);
});

test("VERSION suit le package.json (0.3.0)", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, "package.json"), "utf8"));
  assert.equal(zbundle.VERSION, pkg.version);
  assert.equal(zbundle.VERSION, "0.1.0");
});

// ══════════════════ LE CLI ══════════════════
// On lance le VRAI binaire : c'est la seule façon de vérifier ce qui compte
// pour un outil en ligne de commande — la séparation stdout/stderr, les codes
// de sortie, et la lisibilité des refus.

const { execFileSync, spawnSync } = require("node:child_process");
const os = require("node:os");

const CLI = path.join(__dirname, "dist", "cli.js");

/** Lance le CLI et rend { status, stdout, stderr } sans jamais throw. */
function cli(args, cwd) {
  const r = spawnSync(process.execPath, [CLI, ...args], {
    cwd: cwd ?? path.join(__dirname, "..", "..", "playground", "projects", "shake-barrel"),
    encoding: "utf8",
  });
  return { status: r.status, stdout: r.stdout, stderr: r.stderr.replace(/\x1b\[[0-9;]*m/g, "") };
}

test("CLI : --help et --version", () => {
  const help = cli(["--help"]);
  assert.equal(help.status, 0);
  assert.match(help.stdout, /Usage:/);
  assert.match(help.stdout, /--watch/);

  const v = cli(["--version"]);
  assert.equal(v.status, 0);
  assert.equal(v.stdout.trim(), zbundle.VERSION);
});

test("CLI : sans argument, l'aide et un code d'erreur", () => {
  const r = cli([]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /Usage:/);
});

test("CLI : le bundle va sur stdout, les stats sur stderr", () => {
  const r = cli(["main.js"]);
  assert.equal(r.status, 0);
  // stdout est du JS PUR : redirigeable tel quel dans un fichier.
  assert.match(r.stdout, /^\/\/ Genere par zbundle/);
  assert.doesNotMatch(r.stdout, /modules/); // aucune statistique dedans
  // Les chiffres sont sur stderr.
  assert.match(r.stderr, /3 modules/);
  assert.match(r.stderr, /octets/);
});

test("CLI : -o écrit le fichier et laisse stdout vide", () => {
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

test("CLI : --quiet supprime les statistiques", () => {
  const r = cli(["main.js", "--quiet"]);
  assert.equal(r.status, 0);
  assert.equal(r.stderr, "");
  assert.ok(r.stdout.length > 0);
});

test("CLI : --graph affiche l'arbre au lieu de bundler", () => {
  const r = cli(["main.js", "--graph"]);
  assert.equal(r.status, 0);
  assert.match(r.stdout, /main\.js/);
  assert.match(r.stdout, /modules,.*edges/);
  assert.doesNotMatch(r.stdout, /Genere par zbundle/); // pas de bundle
});

test("CLI : --dead liste les éliminations avec leur raison", () => {
  const r = cli(["main.js", "--dead", "--quiet"], path.join(__dirname, "..", "..", "playground", "projects", "shake-diamond"));
  assert.equal(r.status, 0);
  assert.match(r.stderr, /elimine par le tree-shaking/);
  assert.match(r.stderr, /heavy\.js/);
  assert.match(r.stderr, /module entierement elimine/);
});

test("CLI : --format iife enveloppe, et n'exporte rien", () => {
  const r = cli(["main.js", "-f", "iife"]);
  assert.equal(r.status, 0);
  assert.match(r.stdout, /\(\(\) => \{/);
  assert.match(r.stdout, /\}\)\(\);\s*$/);
  assert.doesNotMatch(r.stdout, /^export /m);
});

test("CLI : --format iife REFUSE clairement s'il y a des externals", () => {
  const r = cli(["main.js", "-f", "iife"], path.join(__dirname, "..", "..", "playground", "projects", "external"));
  assert.equal(r.status, 1);
  assert.match(r.stderr, /incompatible avec des imports externes/);
  assert.match(r.stderr, /--format esm/); // dit quoi faire
  assert.equal(r.stdout, ""); // rien d'invalide n'est sorti
});

test("CLI : un format inconnu est refusé", () => {
  const r = cli(["main.js", "-f", "umd"]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /format inconnu 'umd'/);
  assert.match(r.stderr, /esm, iife/);
});

test("CLI : entry introuvable -> message court, code 1", () => {
  const r = cli(["./nexiste-pas.js"]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /entry introuvable/);
});

test("CLI : un refus du linker remonte tel quel, avec son explication", () => {
  const r = cli(["main.js"], path.join(__dirname, "..", "..", "playground", "refusals", "top-level-await"));
  assert.equal(r.status, 1);
  assert.match(r.stderr, /top-level await/);
  assert.match(r.stderr, /Deplacez-le dans une/); // le conseil est préservé
  assert.equal(r.stdout, "");
});

test("CLI : --watch exige -o (sinon le bundle part dans le terminal)", () => {
  const r = cli(["main.js", "--watch"]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /--watch demande -o/);
});

test("CLI : deux entries à la fois sont refusées", () => {
  const r = cli(["main.js", "autre.js"]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /une seule entry/);
});
