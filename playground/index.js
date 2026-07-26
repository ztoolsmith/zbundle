// Bac à sable : construit le graphe d'une entry et l'affiche en arbre indenté
// + les stats. Le pendant du playground de zcompiler (qui affiche l'AST).
//
// Usage :
//   node index.js                                  # les fixtures du corpus
//   node index.js ../corpus/fixtures/diamond/entry.js
//   node index.js <entry> --json                   # la structure brute
//
// Prérequis : zbundle buildé (pnpm --filter zbundle build).
import zbundle from "zbundle";
import path from "node:path";
import fs from "node:fs";

const args = process.argv.slice(2);
const asJson = args.includes("--json");
const entries = args.filter((a) => !a.startsWith("--"));

// Sans argument : toutes les fixtures, pour voir d'un coup ce que le graphe sait.
const HERE = path.dirname(new URL(import.meta.url).pathname);
const fixtures = path.join(HERE, "..", "corpus", "fixtures");
const targets =
  entries.length > 0
    ? entries
    : fs
        .readdirSync(fixtures, { withFileTypes: true })
        .filter((e) => e.isDirectory())
        .map((e) => entryOf(path.join(fixtures, e.name)))
        .filter(Boolean);

// L'entry d'une fixture = le seul fichier nommé `entry.*`.
function entryOf(dir) {
  const hit = fs.readdirSync(dir).find((f) => /^entry\./.test(f));
  return hit ? path.join(dir, hit) : null;
}

for (const entry of targets) {
  console.log(`\n\x1b[1m${path.relative(process.cwd(), entry)}\x1b[0m`);
  const t0 = process.hrtime.bigint();
  let out;
  try {
    out = asJson ? JSON.stringify(zbundle.graph(entry), null, 2) : zbundle.graphPrint(entry);
  } catch (err) {
    console.log(`  ⚠ ${err.message.split("\n").join("\n  ")}`);
    continue;
  }
  const ms = Number(process.hrtime.bigint() - t0) / 1e6;
  console.log(out.replace(/^/gm, "  "));
  console.log(`  (${ms.toFixed(2)} ms aller-retour depuis JS)`);
}
