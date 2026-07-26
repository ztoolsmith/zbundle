// Corpus test harness: the graph's arbiter.
//
// Usage:
//   node corpus.js --graph <dir>   # handmade fixtures, compared to their expected.json
//   node corpus.js --real <dir>    # real projects: no crash + plausible stats
//
// Two regimes, two requirements (the lesson from zcompiler's corpus):
//
//   --graph: each subdirectory of <dir> is a fixture = a handmade mini-project
//     plus an `expected.json` saying EXACTLY what the graph must contain
//     (modules, edges, externals, cycles). Strict comparison, including edge
//     ORDER — source order is a contract (the bundle's execution order derives
//     from it).
//
//   --real: real code, no oracle. We check what is checkable: the graph builds,
//     it does not loop, zero parse errors, and the statistics are printed for
//     human eyes.
//
// Non-zero exit on failure: usable as a CI gate.
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

// ---- normalization helpers: the graph speaks in CANONICAL ABSOLUTE paths,
// the expected.json files in paths relative to the fixture (readable, portable).

const rel = (root, p) => path.relative(root, p).split(path.sep).join("/");

function record(name, msg, detail) {
  failures.push({ name, msg, detail });
}

/** The edges, in comparable form: relative paths, target OR external. */
function normalizeEdges(root, g) {
  return g.edges.map((e) => {
    const out = { from: rel(root, g.modules[e.from].path), specifier: e.specifier, kind: e.kind };
    if (e.to !== null) out.to = rel(root, g.modules[e.to].path);
    else out.external = g.externals[e.external].specifier;
    return out;
  });
}

/** The same shape from expected.json (absent keys stay absent). */
function normalizeExpectedEdges(edges) {
  return (edges ?? []).map((e) => {
    const out = { from: e.from, specifier: e.specifier, kind: e.kind };
    if ("to" in e) out.to = e.to;
    else out.external = e.external;
    return out;
  });
}

/** Cycles, sorted within a cycle AND across cycles: stable comparison. */
function normalizeCycles(root, g) {
  return g.cycles
    .map((c) => c.map((id) => rel(root, g.modules[id].path)).sort())
    .sort((a, b) => a[0].localeCompare(b[0]));
}

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// ---- --graph mode: the fixtures ----

function checkFixture(dir) {
  total++;
  const name = path.basename(dir);
  const expectedPath = path.join(dir, "expected.json");
  if (!fs.existsSync(expectedPath)) {
    record(name, "missing expected.json");
    return;
  }
  const expected = JSON.parse(fs.readFileSync(expectedPath, "utf8"));
  const entry = path.join(dir, expected.entry);

  let g;
  try {
    g = zbundle.graph(entry);
  } catch (err) {
    record(name, "graph threw", err.message);
    return;
  }

  // 1. The modules (as a sorted set: discovery order is a detail).
  const gotModules = g.modules.map((m) => rel(dir, m.path)).sort();
  const wantModules = [...expected.modules].sort();
  if (!same(gotModules, wantModules)) {
    record(name, "modules", `expected ${JSON.stringify(wantModules)}\n      got      ${JSON.stringify(gotModules)}`);
    return;
  }

  // 2. The entry really is the entry.
  if (rel(dir, g.modules[g.entry].path) !== expected.entry) {
    record(name, "entry", `expected ${expected.entry}, got ${rel(dir, g.modules[g.entry].path)}`);
    return;
  }

  // 3. The edges, IN ORDER (contract: ascending `from`, then source order).
  const gotEdges = normalizeEdges(dir, g);
  const wantEdges = normalizeExpectedEdges(expected.edges);
  if (!same(gotEdges, wantEdges)) {
    record(name, "edges", diffLines(wantEdges, gotEdges));
    return;
  }

  // 4. The externals (specifier + importer count), in first-encounter order.
  const gotExternals = g.externals.map((e) => ({ specifier: e.specifier, count: e.count }));
  const wantExternals = expected.externals ?? [];
  if (!same(gotExternals, wantExternals)) {
    record(name, "externals", diffLines(wantExternals, gotExternals));
    return;
  }

  // 5. The cycles.
  const gotCycles = normalizeCycles(dir, g);
  const wantCycles = (expected.cycles ?? []).map((c) => [...c].sort()).sort((a, b) => a[0].localeCompare(b[0]));
  if (!same(gotCycles, wantCycles)) {
    record(name, "cycles", diffLines(wantCycles, gotCycles));
    return;
  }

  // 6. Optional keys: the parse formats and the total parse-error count.
  if (expected.formats) {
    for (const [file, want] of Object.entries(expected.formats)) {
      const mod = g.modules.find((m) => rel(dir, m.path) === file);
      if (mod.format !== want) {
        record(name, "format", `${file}: expected ${want}, got ${mod.format}`);
        return;
      }
    }
  }
  if (expected.parse_errors !== undefined && g.stats.parse_errors !== expected.parse_errors) {
    record(name, "parse_errors", `expected ${expected.parse_errors}, got ${g.stats.parse_errors}`);
    return;
  }

  // 7. The debug printer must never crash (humans will read it).
  try {
    zbundle.graphPrint(entry);
  } catch (err) {
    record(name, "graphPrint crashed", err.message);
    return;
  }

  ok++;
  const s = g.stats;
  console.log(
    `  ✔ ${name.padEnd(18)} ${String(s.modules).padStart(3)} modules  ${String(s.edges).padStart(3)} edges  ` +
      `${s.externals} externals  ${s.cycles} cycles  (${s.build_ms.toFixed(2)} ms)`,
  );
}

/** Both lists side by side, one entry per line — readable on failure. */
function diffLines(want, got) {
  const n = Math.max(want.length, got.length);
  const lines = [];
  for (let i = 0; i < n; i++) {
    const a = JSON.stringify(want[i] ?? null);
    const b = JSON.stringify(got[i] ?? null);
    lines.push(`${a === b ? "  " : "≠ "}expected ${a}\n        got      ${b}`);
  }
  return lines.join("\n      ");
}

// ---- --real mode: the real-world projects ----

/** A real project's entries: package.json's `main`/`module`, otherwise index. */
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
    console.log(`  (no project in ${dir} — run \`npm install\` in corpus/real/)`);
    return;
  }
  for (const { name, entry } of entries) {
    total++;
    let g;
    const t0 = process.hrtime.bigint();
    try {
      g = zbundle.graph(entry);
    } catch (err) {
      record(name, "graph threw", err.message.split("\n")[0]);
      continue;
    }
    const ms = Number(process.hrtime.bigint() - t0) / 1e6;
    const s = g.stats;
    // The only oracle-free assertions: it stands up.
    if (s.modules < 1) {
      record(name, "empty graph");
      continue;
    }
    if (s.parse_errors > 0) {
      record(name, "parse errors (a gap on zcompiler's side)", `${s.parse_errors} diagnostics`);
      continue;
    }
    ok++;
    console.log(
      `  ✔ ${name.padEnd(12)} ${String(s.modules).padStart(4)} modules  ${String(s.edges).padStart(5)} edges  ` +
        `${s.externals} externals  ${s.cycles} cycles  ${s.parse_errors} err  ` +
        `(${s.build_ms.toFixed(1)} ms native / ${ms.toFixed(1)} ms from JS)`,
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
  console.log("── Failures ──");
  for (const f of failures) {
    console.log(`  ${f.name} : ${f.msg}`);
    if (f.detail) console.log(`      ${f.detail}`);
  }
  console.log("");
  process.exitCode = 1;
}
