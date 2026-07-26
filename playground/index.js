// Sandbox: builds the graph of an entry and prints it as an indented tree plus
// statistics. The counterpart of zcompiler's playground (which prints the AST).
//
// Usage:
//   node index.js                                  # the corpus fixtures
//   node index.js ../corpus/fixtures/diamond/entry.js
//   node index.js <entry> --json                   # the raw structure
//
// Requires zbundle to be built (pnpm --filter zbundle build).
import zbundle from "zbundle";
import path from "node:path";
import fs from "node:fs";

const args = process.argv.slice(2);
const asJson = args.includes("--json");
const entries = args.filter((a) => !a.startsWith("--"));

// Without arguments: every fixture, to see at a glance what the graph knows.
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

// A fixture's entry = the only file named `entry.*`.
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
  console.log(`  (${ms.toFixed(2)} ms round-trip from JS)`);
}
