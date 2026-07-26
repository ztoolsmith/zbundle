// Bundler un projet et REGARDER ce qui sort. Le pendant du debug printer de
// zcompiler (qui montrait l'AST) : ici on montre le linking.
//
// Usage :
//   node inspect.mjs                  # liste les projets
//   node inspect.mjs barrel           # le bundle de projects/barrel/
//   node inspect.mjs barrel --graph   # + le graphe de modules
//   node inspect.mjs barrel --run     # + l'exécution
//   node inspect.mjs barrel --dead    # + ce que le tree-shaking a éliminé (original vs bundle)
//   node inspect.mjs ../chemin/main.js
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import zbundle from "zbundle";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROJECTS = path.join(HERE, "projects");

const args = process.argv.slice(2);
const flags = new Set(args.filter((a) => a.startsWith("--")));
const target = args.find((a) => !a.startsWith("--"));

const B = "\x1b[1m";
const DIM = "\x1b[2m";
const OFF = "\x1b[0m";

if (!target) {
  console.log(`\n${B}Projets disponibles${OFF} ${DIM}(playground/projects/)${OFF}\n`);
  for (const e of fs.readdirSync(PROJECTS, { withFileTypes: true })) {
    if (!e.isDirectory()) continue;
    const dir = path.join(PROJECTS, e.name);
    const files = fs.readdirSync(dir).filter((f) => /\.(m?js|jsx|tsx|ts)$/.test(f));
    console.log(`  ${e.name.padEnd(16)} ${DIM}${files.length} fichiers${OFF}`);
  }
  console.log(`\n  node inspect.mjs <projet> [--graph] [--run]\n`);
  process.exit(0);
}

/** Un nom de projet, ou un chemin direct vers une entry. */
function entryOf(t) {
  const dir = path.join(PROJECTS, t);
  if (fs.existsSync(dir) && fs.statSync(dir).isDirectory()) {
    const hit = fs.readdirSync(dir).find((f) => /^main\./.test(f));
    if (!hit) throw new Error(`pas de main.* dans ${dir}`);
    return path.join(dir, hit);
  }
  return path.resolve(t);
}

const entry = entryOf(target);
const dir = path.dirname(entry);
console.log(`\n${B}${path.relative(process.cwd(), entry)}${OFF}`);

if (flags.has("--graph")) {
  console.log(`\n${B}── le graphe ──${OFF}`);
  console.log(zbundle.graphPrint(entry).replace(/^/gm, "  "));
}

let result;
try {
  result = flags.has("--dead") ? zbundle.bundleReport(entry) : zbundle.bundleStats(entry);
} catch (err) {
  console.log(`\n\x1b[31m✘ bundle refusé${OFF}\n`);
  console.log(err.message.replace(/^/gm, "  "));
  console.log("");
  process.exit(1);
}

const s = result.stats;
console.log(`\n${B}── le bundle ──${OFF}`);
console.log(result.code.replace(/^/gm, "  "));

if (flags.has("--dead")) {
  console.log(`${B}── ce que le tree-shaking a éliminé ──${OFF}`);
  if (result.dead.length === 0) {
    console.log(`  ${DIM}(rien : tout était atteignable)${OFF}\n`);
  } else {
    // Groupé par module : c'est comme ça qu'on lit un shaking.
    const byModule = new Map();
    for (const d of result.dead) {
      if (!byModule.has(d.module)) byModule.set(d.module, []);
      byModule.get(d.module).push(d);
    }
    for (const [mod, list] of byModule) {
      console.log(`  ${mod}`);
      for (const d of list) {
        console.log(`    ${DIM}L${String(d.line).padEnd(3)}${OFF} ${d.snippet}`);
        console.log(`         ${DIM}↳ ${d.reason}${OFF}`);
      }
    }
    console.log("");
  }
}

console.log(`${B}── les stats ──${OFF}`);
const pct = ((100 * s.output_bytes) / s.input_bytes).toFixed(1);
console.log(`  ${s.modules} modules émis, ${s.modules_dropped} éliminés, ${s.externals} externals, ${s.renamed} renommés`);
console.log(`  tree-shaking : ${s.statements_kept} statements gardés, ${s.statements_dropped} éliminés`);
console.log(`  ${s.input_bytes} → ${s.output_bytes} octets (${pct} %) en ${s.bundle_ms.toFixed(2)} ms`);

if (flags.has("--run")) {
  console.log(`\n${B}── exécution ──${OFF}`);
  const file = path.join(dir, ".inspect.mjs");
  fs.writeFileSync(file, result.code);
  try {
    const out = execFileSync(process.execPath, [file], { cwd: dir, encoding: "utf8" });
    console.log(out.replace(/^/gm, "  "));
  } catch (err) {
    console.log(`  \x1b[31m${(err.stderr || err.message).trim()}${OFF}`);
  } finally {
    fs.rmSync(file, { force: true });
  }
}
console.log("");
