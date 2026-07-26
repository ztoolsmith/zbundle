// LE JUGE SUPRÊME de la v0.2 : le bundle produit-il le MÊME résultat que le
// projet d'origine ?
//
//   pour chaque projet de projects/ :
//     1. exécuter l'ORIGINAL dans Node        → stdout de référence
//     2. bundler avec zbundle                 → un seul fichier
//     3. exécuter LE BUNDLE dans Node         → stdout du bundle
//     4. diff. Identique = vert.
//
// C'est le round-trip du bundler, le pendant exact du `parse ∘ print` de
// zcompiler : la seule vérification qui ne peut pas se tromper elle-même.
//
// Puis les REFUS (refusals/) : chacun DOIT échouer, avec un message qui
// explique. Un refus silencieux ou un bundle faux serait pire qu'une erreur.
//
// Usage :
//   node run.mjs                 # tout
//   node run.mjs diamond cycle   # ces projets seulement
//   node run.mjs --keep          # garde les bundles générés (pour les lire)
//
// La référence pour un projet TS/JSX : Node ne sait pas exécuter `.tsx`, donc
// chaque module est compilé INDIVIDUELLEMENT par zcompiler (strip types + lower
// JSX) dans un dossier miroir, puis exécuté par le loader ESM de Node. Ce n'est
// pas circulaire : ça isole exactement ce qu'on teste — le LINKING.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import zbundle from "zbundle";
import zcompiler from "zcompiler";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROJECTS = path.join(HERE, "projects");
const REFUSALS = path.join(HERE, "refusals");

const args = process.argv.slice(2);
const keep = args.includes("--keep");
const only = args.filter((a) => !a.startsWith("--"));

const GREEN = "\x1b[32m";
const RED = "\x1b[31m";
const DIM = "\x1b[2m";
const OFF = "\x1b[0m";

let pass = 0;
const failures = [];

/** L'entry d'un projet : le seul `main.*`. */
function entryOf(dir) {
  const hit = fs.readdirSync(dir).find((f) => /^main\.(m?js|jsx|tsx|ts)$/.test(f));
  return hit ? path.join(dir, hit) : null;
}

function run(file, cwd) {
  return execFileSync(process.execPath, [file], {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

/** Tous les fichiers source d'un projet (hors node_modules et artefacts). */
function sources(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name === "node_modules" || e.name.startsWith(".")) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...sources(p));
    else if (/\.(m?js|jsx|tsx|ts)$/.test(e.name)) out.push(p);
  }
  return out;
}

/**
 * La référence pour un projet contenant du TS/JSX : un miroir où chaque module
 * est compilé SÉPARÉMENT par zcompiler, puis exécuté par Node. Les specifiers
 * `./x.tsx` deviennent `./x.js` (Node exige l'extension réelle).
 */
function mirrorCompile(dir) {
  const mirror = path.join(dir, ".reference");
  fs.rmSync(mirror, { recursive: true, force: true });
  for (const file of sources(dir)) {
    const rel = path.relative(dir, file);
    const src = fs.readFileSync(file, "utf8");
    const ext = path.extname(file);
    let code;
    if (ext === ".tsx") code = zcompiler.jsxTransform(zcompiler.stripTypesTsx(src));
    else if (ext === ".ts") code = zcompiler.stripTypes(src);
    else if (ext === ".jsx") code = zcompiler.jsxTransform(src);
    else code = src;
    // `from './x.tsx'` -> `from './x.js'`
    code = code.replace(/(['"])(\.\.?\/[^'"]*)\.(tsx|ts|jsx|mjs)\1/g, "$1$2.js$1");
    const out = path.join(mirror, rel.replace(/\.(tsx|ts|jsx|mjs)$/, ".js"));
    fs.mkdirSync(path.dirname(out), { recursive: true });
    fs.writeFileSync(out, code);
  }
  // Les node_modules du projet doivent rester atteignables depuis le miroir :
  // il est DANS le projet, donc la résolution Node remonte naturellement.
  return path.join(mirror, "main.js");
}

const needsCompile = (dir) => sources(dir).some((f) => /\.(tsx|ts|jsx)$/.test(f));

function checkProject(dir) {
  const name = path.basename(dir);
  const entry = entryOf(dir);
  if (!entry) return record(name, "aucun main.* dans le projet");

  // 1. l'original (directement, ou via le miroir compilé pour TS/JSX)
  let reference;
  let referenceFile = entry;
  try {
    if (needsCompile(dir)) referenceFile = mirrorCompile(dir);
    reference = run(referenceFile, dir);
  } catch (err) {
    return record(name, "l'ORIGINAL ne s'exécute pas", (err.stderr || err.message).trim());
  }

  // 2. le bundle
  let code;
  let stats;
  try {
    const r = zbundle.bundleStats(entry);
    code = r.code;
    stats = r.stats;
  } catch (err) {
    return record(name, "bundle() a échoué", err.message);
  }

  // Écrit DANS le projet : les externals (`react/jsx-runtime`, …) doivent se
  // résoudre depuis là comme pour l'original.
  const bundleFile = path.join(dir, ".bundle.mjs");
  fs.writeFileSync(bundleFile, code);

  // 3. exécution du bundle
  let actual;
  try {
    actual = run(bundleFile, dir);
  } catch (err) {
    return record(name, "LE BUNDLE ne s'exécute pas", (err.stderr || err.message).trim());
  }

  // 4. le verdict
  if (actual !== reference) {
    return record(name, "stdout DIFFÈRE", diff(reference, actual));
  }

  // Bonus, gratuit : le bundle est-il du JS sain, et ne fuit-il aucun nom interne ?
  const health = checkHealth(code, stats);
  if (health) return record(name, health.what, health.detail);

  // v0.3 : le tree-shaking se verifie TEXTUELLEMENT. Un stdout identique prouve
  // que rien de vivant n'a ete supprime ; il ne prouve pas que le mort l'a ete.
  const shaking = checkShaking(dir, entry, code);
  if (shaking) return record(name, shaking.what, shaking.detail);

  if (!keep) fs.rmSync(bundleFile, { force: true });
  fs.rmSync(path.join(dir, ".reference"), { recursive: true, force: true });
  pass++;
  const pct = ((100 * stats.output_bytes) / stats.input_bytes).toFixed(0);
  const shaken =
    stats.statements_dropped > 0 || stats.modules_dropped > 0
      ? `${DIM}−${stats.statements_dropped} stmt −${stats.modules_dropped} mod${OFF}  `
      : "";
  console.log(
    `  ${GREEN}✔${OFF} ${name.padEnd(16)} ${String(stats.modules).padStart(3)} modules  ` +
      `${stats.externals} ext  ${String(stats.renamed).padStart(2)} renommés  ` +
      `${shaken}${stats.input_bytes}→${stats.output_bytes} o (${pct} %)  ${DIM}${stats.bundle_ms.toFixed(2)} ms${OFF}`,
  );
}

/**
 * Les en-têtes `// expect-absent:` / `// expect-present:` du `main.*` : la seule
 * façon de prouver que le tree-shaking a mordu. Un stdout identique montre que
 * rien de VIVANT n'a été supprimé — pas que le MORT a disparu.
 */
function checkShaking(dir, entry, code) {
  const head = fs.readFileSync(entry, "utf8");
  const list = (key) => {
    const m = head.match(new RegExp(`//\\s*expect-${key}:\\s*(.+)`));
    return m ? m[1].trim().split(/\s+/) : [];
  };
  const absent = list("absent").filter((n) => code.includes(n));
  if (absent.length) {
    return { what: "du code MORT est encore là", detail: absent.join(", ") };
  }
  const present = list("present").filter((n) => !code.includes(n));
  if (present.length) {
    return { what: "du code VIVANT a été supprimé", detail: present.join(", ") };
  }
  return null;
}

/**
 * Le bundle doit être du JS sain (zcompiler le reparse sans erreur ni
 * diagnostic) et ne référencer AUCUN nom interne fuité : ses `unresolved`
 * doivent tous être des globals ou des noms importés d'externals.
 */
function checkHealth(code, stats) {
  const errs = zcompiler.parseErrors(code);
  if (errs.length) return { what: "le bundle ne reparse PAS", detail: errs[0].message };
  const sem = zcompiler.semantic(code);
  if (sem.diagnostics.length) {
    return { what: "diagnostic semantic sur le bundle", detail: sem.diagnostics.join(" | ") };
  }
  // Les noms importés en tête du bundle sont des bindings, donc pas unresolved ;
  // ce qui reste doit être un global connu.
  const leaked = [...sem.unresolved].filter((n) => !GLOBALS.has(n));
  if (leaked.length) {
    return { what: "des noms INTERNES fuient", detail: leaked.join(", ") };
  }
  if (stats.modules < 1) return { what: "bundle vide" };
  return null;
}

const GLOBALS = new Set([
  "console", "process", "globalThis", "Math", "JSON", "Object", "Array", "String",
  "Number", "Boolean", "Date", "RegExp", "Error", "TypeError", "RangeError",
  "Promise", "Symbol", "Map", "Set", "WeakMap", "WeakSet", "Proxy", "Reflect",
  "BigInt", "Infinity", "NaN", "undefined", "URL", "URLSearchParams", "Buffer",
  "setTimeout", "clearTimeout", "setInterval", "clearInterval", "queueMicrotask",
  "structuredClone", "TextEncoder", "TextDecoder", "fetch", "AbortController",
  // Host / feature-detection : du vrai code (lodash…) teste leur existence.
  "Function", "ArrayBuffer", "DataView", "Uint8Array", "Float64Array", "parseInt",
  "parseFloat", "isNaN", "isFinite", "encodeURIComponent", "decodeURIComponent",
  "global", "self", "window", "document", "module", "exports", "require",
  "arguments", "WeakRef", "FinalizationRegistry", "Intl", "Atomics",
]);

function diff(expected, actual) {
  const a = expected.split("\n");
  const b = actual.split("\n");
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if (a[i] !== b[i]) {
      return `ligne ${i + 1}\n        attendu : ${JSON.stringify(a[i] ?? null)}\n        obtenu  : ${JSON.stringify(b[i] ?? null)}`;
    }
  }
  return "(longueurs différentes)";
}

// ---- les refus : l'erreur EST le comportement attendu ----

function checkRefusal(dir) {
  const name = path.basename(dir);
  const entry = entryOf(dir);
  const expected = (fs.readFileSync(entry, "utf8").match(/expect-error:\s*(.+)/) ?? [])[1];
  if (!expected) return record(name, "en-tête `// expect-error: …` manquant");

  let message = null;
  try {
    zbundle.bundle(entry);
  } catch (err) {
    message = err.message;
  }
  if (message === null) {
    return record(name, `AURAIT DÛ être refusé (${expected})`, "bundle() a réussi");
  }
  // Le message doit expliquer, pas seulement échouer.
  if (message.split("\n").length < 2) {
    return record(name, "refus sans explication", message);
  }
  pass++;
  console.log(`  ${GREEN}✔${OFF} ${name.padEnd(15)} ${DIM}refusé : ${message.split("\n")[0]}${OFF}`);
}

function record(name, what, detail) {
  failures.push({ name, what, detail });
  console.log(`  ${RED}✘${OFF} ${name.padEnd(15)} ${what}`);
}

// ---- run ----

const wanted = (d) => only.length === 0 || only.includes(path.basename(d));
const dirsIn = (root) =>
  fs
    .readdirSync(root, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => path.join(root, e.name))
    .filter(wanted)
    .sort();

console.log(`\n── projets : l'original et le bundle doivent dire la MÊME chose ──`);
for (const dir of dirsIn(PROJECTS)) checkProject(dir);

const refusalDirs = dirsIn(REFUSALS);
if (refusalDirs.length) {
  console.log(`\n── refus : chaque limite v0.2 doit produire une erreur CLAIRE ──`);
  for (const dir of refusalDirs) checkRefusal(dir);
}

const total = pass + failures.length;
console.log(`\n${pass}/${total}${failures.length ? "" : "  — le bundle dit exactement ce que dit le projet"}\n`);

if (failures.length) {
  console.log("── Échecs ──");
  for (const f of failures) {
    console.log(`  ${f.name} : ${f.what}`);
    if (f.detail) console.log(`      ${f.detail.split("\n").join("\n      ")}`);
  }
  console.log("");
  process.exitCode = 1;
}
