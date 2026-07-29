// Does the zcompiler SITTING NEXT TO US provide what this version of zbundle
// needs? Run before anything is compiled.
//
// **Why this exists.** A Zig dependency declared by `path` takes whatever is on
// disk. Locally that is a feature: change zcompiler, rebuild zbundle, done. In
// CI it is a trap — the workflow CLONES zcompiler from GitHub, so a capability
// added downstairs but not yet pushed simply is not there. zbundle 0.4.0 shipped
// straight into it: the release job checked out zcompiler two minutes before the
// printer change landed, and failed with
//
//     error: root source file struct 'printer' has no member named 'Mapping'
//
// which says nothing about the actual problem. This script says it instead, and
// says it before a single file is compiled.
//
// The list below is the same contract as "Version minimale de zcompiler" in
// CLAUDE.md, in executable form: adding a capability to the list is how a future
// version states its requirement.
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";

const HERE = dirname(fileURLToPath(import.meta.url));
// The sibling convention of the org, the same one `build.zig.zon` encodes.
const NATIVE = resolve(HERE, "..", "..", "..", "..", "zcompiler", "packages", "zcompiler", "native");

/** What zbundle imports from zcompiler, and the version that introduced it. */
const REQUIRED = [
  { file: "semantic.zig", symbol: "pub fn moduleRecords", since: "0.1.0", what: "the module graph" },
  { file: "semantic.zig", symbol: "pub fn moduleInfo", since: "0.3.0", what: "the linker" },
  { file: "mangler.zig", symbol: "pub fn applyRenames", since: "0.3.0", what: "cross-module renaming" },
  { file: "printer.zig", symbol: "pub fn printStatement", since: "0.3.0", what: "recomposing a program" },
  { file: "printer.zig", symbol: "pub const Mapping", since: "0.4.0", what: "source maps" },
  { file: "printer.zig", symbol: "pub const Sink", since: "0.4.0", what: "source maps" },
  { file: "printer.zig", symbol: "pub fn printStatementWith", since: "0.4.0", what: "source maps" },
  { file: "printer.zig", symbol: "pub fn printExpressionWith", since: "0.4.0", what: "source maps" },
  { file: "printer.zig", symbol: "name: bool", since: "0.4.1", what: "the source map `names` field" },
];

if (!existsSync(NATIVE)) {
  process.stderr.write(
    `✘ zcompiler is not next to zbundle.\n` +
      `  expected: ${NATIVE}\n` +
      `  The org clones its repos side by side; build.zig.zon points at that path.\n`,
  );
  process.exit(1);
}

const cache = new Map();
const read = (file) => {
  if (!cache.has(file)) {
    const p = join(NATIVE, file);
    cache.set(file, existsSync(p) ? readFileSync(p, "utf8") : null);
  }
  return cache.get(file);
};

const missing = REQUIRED.filter((r) => {
  const src = read(r.file);
  return src === null || !src.includes(r.symbol);
});

if (missing.length > 0) {
  const worst = missing.reduce((a, b) => (a.since > b.since ? a : b)).since;
  process.stderr.write(
    `✘ the zcompiler next door is too old for this zbundle.\n\n` +
      missing.map((m) => `    ${m.file}: ${m.symbol}  (zcompiler ${m.since} — ${m.what})`).join("\n") +
      `\n\n  zbundle needs zcompiler >= ${worst}.\n` +
      `  If you just added this capability downstairs: COMMIT AND PUSH zcompiler\n` +
      `  first, wait for its CI, and only then release zbundle. A Zig \`path\`\n` +
      `  dependency takes what is on disk — and CI clones it from GitHub.\n`,
  );
  process.exit(1);
}

process.stdout.write(`✔ zcompiler provides the ${REQUIRED.length} capabilities zbundle needs\n`);
