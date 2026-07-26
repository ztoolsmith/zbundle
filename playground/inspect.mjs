// Bundle a project and LOOK at what comes out. The counterpart of zcompiler's
// debug printer (which showed the AST): here we show the linking.
//
// Usage:
//   node inspect.mjs                  # list the projects
//   node inspect.mjs barrel           # the bundle of projects/barrel/
//   node inspect.mjs barrel --graph   # + the module graph
//   node inspect.mjs barrel --run     # + execution
//   node inspect.mjs barrel --dead    # + what tree-shaking removed
//   node inspect.mjs ../path/main.js
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
  console.log(`\n${B}Available projects${OFF} ${DIM}(playground/projects/)${OFF}\n`);
  for (const e of fs.readdirSync(PROJECTS, { withFileTypes: true })) {
    if (!e.isDirectory()) continue;
    const dir = path.join(PROJECTS, e.name);
    const files = fs.readdirSync(dir).filter((f) => /\.(m?js|jsx|tsx|ts)$/.test(f));
    console.log(`  ${e.name.padEnd(16)} ${DIM}${files.length} files${OFF}`);
  }
  console.log(`\n  node inspect.mjs <projet> [--graph] [--run]\n`);
  process.exit(0);
}

/** A project name, or a direct path to an entry. */
function entryOf(t) {
  const dir = path.join(PROJECTS, t);
  if (fs.existsSync(dir) && fs.statSync(dir).isDirectory()) {
    const hit = fs.readdirSync(dir).find((f) => /^main\./.test(f));
    if (!hit) throw new Error(`no main.* in ${dir}`);
    return path.join(dir, hit);
  }
  return path.resolve(t);
}

const entry = entryOf(target);
const dir = path.dirname(entry);
console.log(`\n${B}${path.relative(process.cwd(), entry)}${OFF}`);

if (flags.has("--graph")) {
  console.log(`\n${B}── the graph ──${OFF}`);
  console.log(zbundle.graphPrint(entry).replace(/^/gm, "  "));
}

let result;
try {
  result = flags.has("--dead") ? zbundle.bundleReport(entry) : zbundle.bundleStats(entry);
} catch (err) {
  console.log(`\n\x1b[31m✘ bundle refused${OFF}\n`);
  console.log(err.message.replace(/^/gm, "  "));
  console.log("");
  process.exit(1);
}

const s = result.stats;
console.log(`\n${B}── the bundle ──${OFF}`);
console.log(result.code.replace(/^/gm, "  "));

if (flags.has("--dead")) {
  console.log(`${B}── what tree-shaking removed ──${OFF}`);
  if (result.dead.length === 0) {
    console.log(`  ${DIM}(nothing: everything was reachable)${OFF}\n`);
  } else {
    // Grouped by module: that is how you read a shaking.
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

console.log(`${B}── the stats ──${OFF}`);
const pct = ((100 * s.output_bytes) / s.input_bytes).toFixed(1);
console.log(`  ${s.modules} modules emitted, ${s.modules_dropped} eliminated, ${s.externals} externals, ${s.renamed} renamed`);
console.log(`  tree-shaking: ${s.statements_kept} statements kept, ${s.statements_dropped} eliminated`);
console.log(`  ${s.input_bytes} → ${s.output_bytes} bytes (${pct} %) in ${s.bundle_ms.toFixed(2)} ms`);

if (flags.has("--run")) {
  console.log(`\n${B}── execution ──${OFF}`);
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
