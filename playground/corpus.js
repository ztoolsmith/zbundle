// Harnais de test sur corpus : le juge de paix du graphe.
//
// Usage :
//   node corpus.js --graph <dir>   # les fixtures fabriquées, comparées à leur expected.json
//   node corpus.js --real <dir>    # les vrais projets : no-crash + stats plausibles
//
// Deux régimes, deux exigences (c'est la leçon du corpus de zcompiler) :
//
//   --graph : chaque sous-dossier de <dir> est une fixture = un mini-projet
//     fabriqué + un `expected.json` qui dit EXACTEMENT ce que le graphe doit
//     contenir (modules, arêtes, externals, cycles). Comparaison stricte, y
//     compris l'ORDRE des arêtes — l'ordre source est un contrat (c'est de lui
//     que dérivera l'ordre d'exécution du bundle).
//
//   --real : du vrai code, sans oracle. On vérifie ce qui est vérifiable :
//     le graphe se construit, il ne boucle pas, zéro erreur de parse, et les
//     stats sont affichées pour l'œil humain.
//
// Sortie non nulle sur échec : utilisable comme gate en CI.
import zbundle from "zbundle";
import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
const mode = args.includes("--real") ? "real" : "graph";
const dirs = args.filter((a) => !a.startsWith("--"));
if (dirs.length === 0) {
  console.error("usage: node corpus.js [--graph|--real] <dossier> [<dossier>...]");
  process.exit(1);
}

const failures = [];
let ok = 0;
let total = 0;

// ---- helpers de normalisation : le graphe parle en chemins ABSOLUS canoniques,
// les expected.json en chemins relatifs à la fixture (lisibles, portables).

const rel = (root, p) => path.relative(root, p).split(path.sep).join("/");

function record(name, msg, detail) {
  failures.push({ name, msg, detail });
}

/** Les arêtes, en forme comparable : chemins relatifs, cible OU external. */
function normalizeEdges(root, g) {
  return g.edges.map((e) => {
    const out = { from: rel(root, g.modules[e.from].path), specifier: e.specifier, kind: e.kind };
    if (e.to !== null) out.to = rel(root, g.modules[e.to].path);
    else out.external = g.externals[e.external].specifier;
    return out;
  });
}

/** La même forme depuis l'expected.json (les clés absentes restent absentes). */
function normalizeExpectedEdges(edges) {
  return (edges ?? []).map((e) => {
    const out = { from: e.from, specifier: e.specifier, kind: e.kind };
    if ("to" in e) out.to = e.to;
    else out.external = e.external;
    return out;
  });
}

/** Les cycles, triés dans le cycle ET entre cycles : comparaison stable. */
function normalizeCycles(root, g) {
  return g.cycles
    .map((c) => c.map((id) => rel(root, g.modules[id].path)).sort())
    .sort((a, b) => a[0].localeCompare(b[0]));
}

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// ---- mode --graph : les fixtures ----

function checkFixture(dir) {
  total++;
  const name = path.basename(dir);
  const expectedPath = path.join(dir, "expected.json");
  if (!fs.existsSync(expectedPath)) {
    record(name, "expected.json manquant");
    return;
  }
  const expected = JSON.parse(fs.readFileSync(expectedPath, "utf8"));
  const entry = path.join(dir, expected.entry);

  let g;
  try {
    g = zbundle.graph(entry);
  } catch (err) {
    record(name, "graph a levé une erreur", err.message);
    return;
  }

  // 1. Les modules (ensemble, trié : l'ordre de découverte est un détail).
  const gotModules = g.modules.map((m) => rel(dir, m.path)).sort();
  const wantModules = [...expected.modules].sort();
  if (!same(gotModules, wantModules)) {
    record(name, "modules", `attendu ${JSON.stringify(wantModules)}\n      obtenu  ${JSON.stringify(gotModules)}`);
    return;
  }

  // 2. L'entry est bien l'entry.
  if (rel(dir, g.modules[g.entry].path) !== expected.entry) {
    record(name, "entry", `attendu ${expected.entry}, obtenu ${rel(dir, g.modules[g.entry].path)}`);
    return;
  }

  // 3. Les arêtes, DANS L'ORDRE (contrat : `from` croissant, puis ordre source).
  const gotEdges = normalizeEdges(dir, g);
  const wantEdges = normalizeExpectedEdges(expected.edges);
  if (!same(gotEdges, wantEdges)) {
    record(name, "arêtes", diffLines(wantEdges, gotEdges));
    return;
  }

  // 4. Les externals (specifier + nombre d'importeurs), dans l'ordre de 1re rencontre.
  const gotExternals = g.externals.map((e) => ({ specifier: e.specifier, count: e.count }));
  const wantExternals = expected.externals ?? [];
  if (!same(gotExternals, wantExternals)) {
    record(name, "externals", diffLines(wantExternals, gotExternals));
    return;
  }

  // 5. Les cycles.
  const gotCycles = normalizeCycles(dir, g);
  const wantCycles = (expected.cycles ?? []).map((c) => [...c].sort()).sort((a, b) => a[0].localeCompare(b[0]));
  if (!same(gotCycles, wantCycles)) {
    record(name, "cycles", diffLines(wantCycles, gotCycles));
    return;
  }

  // 6. Clés optionnelles : les formats de parse et le total d'erreurs de parse.
  if (expected.formats) {
    for (const [file, want] of Object.entries(expected.formats)) {
      const mod = g.modules.find((m) => rel(dir, m.path) === file);
      if (mod.format !== want) {
        record(name, "format", `${file} : attendu ${want}, obtenu ${mod.format}`);
        return;
      }
    }
  }
  if (expected.parse_errors !== undefined && g.stats.parse_errors !== expected.parse_errors) {
    record(name, "parse_errors", `attendu ${expected.parse_errors}, obtenu ${g.stats.parse_errors}`);
    return;
  }

  // 7. Le debug printer ne doit jamais planter (il sera lu par des humains).
  try {
    zbundle.graphPrint(entry);
  } catch (err) {
    record(name, "graphPrint a planté", err.message);
    return;
  }

  ok++;
  const s = g.stats;
  console.log(
    `  ✔ ${name.padEnd(18)} ${String(s.modules).padStart(3)} modules  ${String(s.edges).padStart(3)} arêtes  ` +
      `${s.externals} externals  ${s.cycles} cycles  (${s.build_ms.toFixed(2)} ms)`,
  );
}

/** Les deux listes côte à côte, une entrée par ligne — lisible sur un échec. */
function diffLines(want, got) {
  const n = Math.max(want.length, got.length);
  const lines = [];
  for (let i = 0; i < n; i++) {
    const a = JSON.stringify(want[i] ?? null);
    const b = JSON.stringify(got[i] ?? null);
    lines.push(`${a === b ? "  " : "≠ "}attendu ${a}\n        obtenu  ${b}`);
  }
  return lines.join("\n      ");
}

// ---- mode --real : les projets-témoins ----

/** Les entries d'un vrai projet : le `main`/`module` du package.json, sinon index. */
function realEntries(dir) {
  const out = [];
  const pkgRoot = path.join(dir, "node_modules");
  if (!fs.existsSync(pkgRoot)) return out;
  for (const name of fs.readdirSync(pkgRoot)) {
    if (name.startsWith(".")) continue;
    const pkgDir = path.join(pkgRoot, name);
    const pkgFile = path.join(pkgDir, "package.json");
    if (!fs.existsSync(pkgFile)) continue;
    const pkg = JSON.parse(fs.readFileSync(pkgFile, "utf8"));
    const candidate = pkg.module ?? (typeof pkg.exports === "string" ? pkg.exports : null) ?? pkg.main ?? "index.js";
    const entry = path.join(pkgDir, candidate);
    if (fs.existsSync(entry) && /\.(m?js|jsx|tsx|ts)$/.test(entry)) out.push({ name, entry });
  }
  return out;
}

function checkReal(dir) {
  const entries = realEntries(dir);
  if (entries.length === 0) {
    console.log(`  (aucun projet dans ${dir} — lancer \`npm install\` dans corpus/real/)`);
    return;
  }
  for (const { name, entry } of entries) {
    total++;
    let g;
    const t0 = process.hrtime.bigint();
    try {
      g = zbundle.graph(entry);
    } catch (err) {
      record(name, "graph a levé une erreur", err.message.split("\n")[0]);
      continue;
    }
    const ms = Number(process.hrtime.bigint() - t0) / 1e6;
    const s = g.stats;
    // Les seules assertions sans oracle : ça tient debout.
    if (s.modules < 1) {
      record(name, "graphe vide");
      continue;
    }
    if (s.parse_errors > 0) {
      record(name, "erreurs de parse (trou côté zcompiler)", `${s.parse_errors} diagnostics`);
      continue;
    }
    ok++;
    console.log(
      `  ✔ ${name.padEnd(12)} ${String(s.modules).padStart(4)} modules  ${String(s.edges).padStart(5)} arêtes  ` +
        `${s.externals} externals  ${s.cycles} cycles  ${s.parse_errors} err  ` +
        `(${s.build_ms.toFixed(1)} ms natif / ${ms.toFixed(1)} ms depuis JS)`,
    );
  }
}

// ---- run ----

console.log(`\n── corpus ${mode} ──`);
for (const dir of dirs) {
  if (mode === "real") {
    checkReal(dir);
  } else {
    const subs = fs
      .readdirSync(dir, { withFileTypes: true })
      .filter((e) => e.isDirectory())
      .map((e) => path.join(dir, e.name))
      .sort();
    for (const sub of subs) checkFixture(sub);
  }
}

const pct = total ? ((100 * ok) / total).toFixed(1) : "0";
console.log(`\n${ok}/${total} (${pct} %)\n`);

if (failures.length) {
  console.log("── Échecs ──");
  for (const f of failures) {
    console.log(`  ${f.name} : ${f.msg}`);
    if (f.detail) console.log(`      ${f.detail}`);
  }
  console.log("");
  process.exitCode = 1;
}
