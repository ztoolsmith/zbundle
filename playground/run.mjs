// THE ULTIMATE JUDGE: does the bundle produce the SAME result as the original
// project?
//
//   for each project in projects/:
//     1. run THE ORIGINAL in Node    -> reference stdout
//     2. bundle it with zbundle      -> a single file
//     3. run THE BUNDLE in Node      -> bundle stdout
//     4. diff. Identical = green.
//
// This is the bundler's round-trip, the exact counterpart of zcompiler's
// `parse ∘ print`: the only check that cannot fool itself.
//
// Then the REFUSALS (refusals/): each one MUST fail, with a message that
// explains. A silent refusal or a wrong bundle would be worse than an error.
//
// Usage:
//   node run.mjs                 # everything
//   node run.mjs diamond cycle   # only those projects
//   node run.mjs --keep          # keep the generated bundles, to read them
//
// The reference for a TS/JSX project: Node cannot execute `.tsx`, so each module
// is compiled INDIVIDUALLY by zcompiler (strip types + lower JSX) into a mirror
// directory, then run by Node's own ESM loader. That is not circular: it isolates
// exactly what we are testing — the LINKING.
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

/** A project's entry: the one `main.*`. */
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

/** All of a project's source files (excluding node_modules and artifacts). */
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
 * The reference for a project containing TS/JSX: a mirror where each module is
 * compiled SEPARATELY by zcompiler, then run by Node. `./x.tsx` specifiers
 * become `./x.js` (Node requires the real extension).
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
  // The project's node_modules must stay reachable from the mirror: it lives
  // INSIDE the project, so Node's resolution walks up naturally.
  return path.join(mirror, "main.js");
}

const needsCompile = (dir) => sources(dir).some((f) => /\.(tsx|ts|jsx)$/.test(f));

function checkProject(dir) {
  const name = path.basename(dir);
  const entry = entryOf(dir);
  if (!entry) return record(name, "no main.* in the project");

  // 1. the original (directly, or through the compiled mirror for TS/JSX)
  let reference;
  let referenceFile = entry;
  try {
    if (needsCompile(dir)) referenceFile = mirrorCompile(dir);
    reference = run(referenceFile, dir);
  } catch (err) {
    return record(name, "THE ORIGINAL does not run", (err.stderr || err.message).trim());
  }

  // 2. the bundle
  let code;
  let stats;
  try {
    const r = zbundle.bundleStats(entry);
    code = r.code;
    stats = r.stats;
  } catch (err) {
    return record(name, "bundle() failed", err.message);
  }

  // Written INSIDE the project: externals (`react/jsx-runtime`, …) must resolve
  // from there just as they do for the original.
  const bundleFile = path.join(dir, ".bundle.mjs");
  fs.writeFileSync(bundleFile, code);

  // 3. running the bundle
  let actual;
  try {
    actual = run(bundleFile, dir);
  } catch (err) {
    return record(name, "THE BUNDLE does not run", (err.stderr || err.message).trim());
  }

  // 4. the verdict
  if (actual !== reference) {
    return record(name, "stdout DIFFERS", diff(reference, actual));
  }

  // Free bonus: is the bundle sane JS, and does it leak no internal name?
  const health = checkHealth(code, stats);
  if (health) return record(name, health.what, health.detail);

  // Tree-shaking is verified TEXTUALLY. Identical stdout proves nothing live was
  // removed; it does not prove the dead was.
  const shaking = checkShaking(dir, entry, code);
  if (shaking) return record(name, shaking.what, shaking.detail);

  // THE IMPORTING WITNESS: exports are a CONTRACT, so they get tested as one.
  // Running the bundle as a script NEVER touches its `export { … }` — that is
  // the hole through which an export regression would slip unnoticed.
  const exports = checkExports(dir, entry, bundleFile);
  if (exports) return record(name, exports.what, exports.detail);

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
      `${stats.externals} ext  ${String(stats.renamed).padStart(2)} renamed  ` +
      `${shaken}${stats.input_bytes}→${stats.output_bytes} B (${pct} %)  ${DIM}${stats.bundle_ms.toFixed(2)} ms${OFF}`,
  );
}

/**
 * THE IMPORTING WITNESS. For a project declaring `// expect-exports:`, we
 * generate a module that **imports the bundle** and checks its contract:
 *
 *   // expect-exports: jamaisUtilisee:function VERSION:string
 *   // expect-call: jamaisUtilisee(42) -> inutile 42
 *
 * `Object.keys` plus `typeof` for each export, then a real call of those an
 * `expect-call` designates. Without this, `export { … }` is never exercised: the
 * harness runs the bundle as a SCRIPT, and a script ignores its exports.
 */
function checkExports(dir, entry, bundleFile) {
  const head = fs.readFileSync(entry, "utf8");
  const wanted = (head.match(/\/\/\s*expect-exports:\s*(.+)/) ?? [])[1];
  if (!wanted) return null;

  const specs = wanted.trim().split(/\s+/).map((s) => {
    const [name, type = "function"] = s.split(":");
    return { name, type };
  });
  const calls = [...head.matchAll(/\/\/\s*expect-call:\s*(.+?)\s*->\s*(.+)/g)].map((m) => ({
    expr: m[1].trim(),
    expected: m[2].trim(),
  }));

  const witness = path.join(dir, ".witness.mjs");
  fs.writeFileSync(
    witness,
    `import * as bundle from ${JSON.stringify("./" + path.basename(bundleFile))};
` +
      `const problems = [];
` +
      `const keys = Object.keys(bundle);
` +
      `for (const { name, type } of ${JSON.stringify(specs)}) {
` +
      `  if (!keys.includes(name)) { problems.push(\`export MANQUANT : \${name} (presents : \${keys.join(", ") || "aucun"})\`); continue; }
` +
      `  const actual = typeof bundle[name];
` +
      `  if (actual !== type) problems.push(\`\${name} : typeof \${actual}, attendu \${type}\`);
` +
      `}
` +
      `for (const { expr, expected } of ${JSON.stringify(calls)}) {
` +
      `  const m = expr.match(/^(\\w+)\\((.*)\\)$/);
` +
      `  if (!m) { problems.push(\`expect-call illisible : \${expr}\`); continue; }
` +
      `  const fn = bundle[m[1]];
` +
      `  if (typeof fn !== "function") { problems.push(\`\${m[1]} n'est pas appelable\`); continue; }
` +
      `  const args = m[2].trim() ? JSON.parse("[" + m[2] + "]") : [];
` +
      `  let got;
` +
      `  try { got = String(fn(...args)); } catch (e) { problems.push(\`\${expr} a leve : \${e.message}\`); continue; }
` +
      `  if (got !== expected) problems.push(\`\${expr} -> \${JSON.stringify(got)}, attendu \${JSON.stringify(expected)}\`);
` +
      `}
` +
      `if (problems.length) { console.error(problems.join("\\n")); process.exit(1); }
`,
  );

  try {
    run(witness, dir);
    return null;
  } catch (err) {
    return { what: "the bundle's export CONTRACT is broken", detail: (err.stderr || err.message).trim() };
  } finally {
    if (!keep) fs.rmSync(witness, { force: true });
  }
}

/**
 * The `// expect-absent:` / `// expect-present:` headers of `main.*`: the only
 * way to prove tree-shaking bit. Identical stdout shows nothing LIVE was
 * removed — not that the DEAD is gone.
 */
function checkShaking(dir, entry, code) {
  const head = fs.readFileSync(entry, "utf8");
  const list = (key) => {
    const m = head.match(new RegExp(`//\\s*expect-${key}:\\s*(.+)`));
    return m ? m[1].trim().split(/\s+/) : [];
  };
  const absent = list("absent").filter((n) => code.includes(n));
  if (absent.length) {
    return { what: "DEAD code is still there", detail: absent.join(", ") };
  }
  const present = list("present").filter((n) => !code.includes(n));
  if (present.length) {
    return { what: "LIVE code was removed", detail: present.join(", ") };
  }
  return null;
}

/**
 * The bundle must be sane JS (zcompiler re-parses it without error or
 * diagnostic) and must reference NO leaked internal name: its `unresolved` names
 * must all be globals or names imported from externals.
 */
function checkHealth(code, stats) {
  const errs = zcompiler.parseErrors(code);
  if (errs.length) return { what: "the bundle does NOT re-parse", detail: errs[0].message };
  const sem = zcompiler.semantic(code);
  if (sem.diagnostics.length) {
    return { what: "semantic diagnostic on the bundle", detail: sem.diagnostics.join(" | ") };
  }
  // Names imported at the top of the bundle are bindings, so not unresolved;
  // whatever remains must be a known global.
  const leaked = [...sem.unresolved].filter((n) => !GLOBALS.has(n));
  if (leaked.length) {
    return { what: "INTERNAL names are leaking", detail: leaked.join(", ") };
  }
  if (stats.modules < 1) return { what: "empty bundle" };
  return null;
}

const GLOBALS = new Set([
  "console", "process", "globalThis", "Math", "JSON", "Object", "Array", "String",
  "Number", "Boolean", "Date", "RegExp", "Error", "TypeError", "RangeError",
  "Promise", "Symbol", "Map", "Set", "WeakMap", "WeakSet", "Proxy", "Reflect",
  "BigInt", "Infinity", "NaN", "undefined", "URL", "URLSearchParams", "Buffer",
  "setTimeout", "clearTimeout", "setInterval", "clearInterval", "queueMicrotask",
  "structuredClone", "TextEncoder", "TextDecoder", "fetch", "AbortController",
  // Host / feature detection: real code (lodash…) tests for their existence.
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
      return `line ${i + 1}\n        expected: ${JSON.stringify(a[i] ?? null)}\n        got     : ${JSON.stringify(b[i] ?? null)}`;
    }
  }
  return "(different lengths)";
}

// ---- refusals: the error IS the expected behaviour ----

function checkRefusal(dir) {
  const name = path.basename(dir);
  const entry = entryOf(dir);
  const expected = (fs.readFileSync(entry, "utf8").match(/expect-error:\s*(.+)/) ?? [])[1];
  if (!expected) return record(name, "missing `// expect-error: …` header");

  let message = null;
  try {
    zbundle.bundle(entry);
  } catch (err) {
    message = err.message;
  }
  if (message === null) {
    return record(name, `SHOULD HAVE been refused (${expected})`, "bundle() succeeded");
  }
  // The message must explain, not merely fail.
  if (message.split("\n").length < 2) {
    return record(name, "refusal without explanation", message);
  }
  pass++;
  console.log(`  ${GREEN}✔${OFF} ${name.padEnd(15)} ${DIM}refused: ${message.split("\n")[0]}${OFF}`);
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

console.log(`\n── projects: the original and the bundle must say the SAME thing ──`);
for (const dir of dirsIn(PROJECTS)) checkProject(dir);

const refusalDirs = dirsIn(REFUSALS);
if (refusalDirs.length) {
  console.log(`\n── refusals: every limitation must produce a CLEAR error ──`);
  for (const dir of refusalDirs) checkRefusal(dir);
}

const total = pass + failures.length;
console.log(`\n${pass}/${total}${failures.length ? "" : "  — the bundle says exactly what the project says"}\n`);

if (failures.length) {
  console.log("── Failures ──");
  for (const f of failures) {
    console.log(`  ${f.name} : ${f.what}`);
    if (f.detail) console.log(`      ${f.detail.split("\n").join("\n      ")}`);
  }
  console.log("");
  process.exitCode = 1;
}
