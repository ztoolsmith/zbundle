// Dress rehearsal for publishing: `npm pack` the main package plus the host's
// platform package into an EMPTY witness, then prove that the PUBLISHED package
// starts — not the one in the repository.
//
// zbundle has TWO surfaces, and they break differently:
//   1. the API     : `require("zbundle").bundle(entry)`
//   2. the COMMAND : `zbundle <entry>`, through the `bin` field
// A release that forgets `dist/` in `files` breaks the second without touching
// the first. A forgotten `prepublish` breaks both. So we test both.
//
// Run from the package directory, AFTER `zignapi build` (+ `--target
// <host-triple>`) and `zignapi prepublish`.
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import process from "node:process";

const PKG = process.cwd();

/** The host's napi-rs triple (must match a built npm/<triple>/). */
function currentTriple() {
  const a = process.arch;
  if (process.platform === "darwin") return `darwin-${a}`;
  if (process.platform === "win32") return `win32-${a}-msvc`;
  if (process.platform === "linux") {
    const rep = process.report.getReport();
    const libc = rep.header?.glibcVersionRuntime ? "gnu" : "musl";
    return `linux-${a}-${libc}`;
  }
  return `${process.platform}-${a}`;
}

function pack(dir, dest) {
  const out = execFileSync("npm", ["pack", "--pack-destination", dest], { cwd: dir, encoding: "utf8" });
  return join(dest, out.trim().split("\n").pop());
}

function extractInto(tgz, targetDir) {
  mkdirSync(targetDir, { recursive: true });
  const tmp = mkdtempSync(join(tmpdir(), "x-"));
  execFileSync("tar", ["-xzf", tgz, "-C", tmp]);
  execFileSync("cp", ["-R", join(tmp, "package") + "/.", targetDir]); // npm wraps things in `package/`
  rmSync(tmp, { recursive: true, force: true });
}

function assert(cond, msg) {
  if (!cond) {
    process.stderr.write("✗ " + msg + "\n");
    process.exit(1);
  }
}

const triple = currentTriple();
if (!readdirSync(join(PKG, "npm")).includes(triple)) {
  throw new Error(`no npm/${triple}/ — run \`zignapi build --target ${triple}\` first`);
}

const witness = mkdtempSync(join(tmpdir(), "zb-witness-"));
const nm = join(witness, "node_modules");
const scope = join(nm, "@zbundle");
mkdirSync(scope, { recursive: true });

extractInto(pack(PKG, witness), join(nm, "zbundle"));
extractInto(pack(join(PKG, "npm", triple), witness), join(scope, `binding-${triple}`));

// A mini-project to bundle INSIDE the witness: two modules, a name collision,
// and dead code — enough to exercise both linking AND tree-shaking.
writeFileSync(
  join(witness, "dep.js"),
  "const helper = (n) => n + 1;\nexport const live = (n) => helper(n) * 2;\nexport const dead = () => 'never';\n",
);
writeFileSync(
  join(witness, "entry.js"),
  "import { live } from './dep.js';\nconst helper = () => 'local';\nconsole.log(live(20), helper());\n",
);

const EXPECT = "42 local\n";

// 1. The API: require("zbundle") -> bindings.js -> the platform package.
const api = execFileSync(
  process.execPath,
  ["-e", `const z=require("zbundle");require("node:fs").writeFileSync("out-api.mjs",z.bundle("./entry.js"))`],
  { cwd: witness, encoding: "utf8" },
);
void api;
const apiRun = execFileSync(process.execPath, ["out-api.mjs"], { cwd: witness, encoding: "utf8" });
assert(apiRun === EXPECT, `unexpected API output: ${JSON.stringify(apiRun)}`);
process.stdout.write("✔ API: require(\"zbundle\").bundle() -> a bundle that runs\n");

// Tree-shaking really bit inside the published package (not just in dev).
const code = execFileSync(
  process.execPath,
  ["-e", `process.stdout.write(require("zbundle").bundle("./entry.js"))`],
  { cwd: witness, encoding: "utf8" },
);
assert(!code.includes("dead"), "tree-shaking did not remove `dead` in the published package");
assert(code.includes("helper$1") || code.includes("helper"), "cross-module renaming disappeared");
process.stdout.write("✔ tree-shaking + renaming active from the published package\n");

// 2. The COMMAND: the `bin` field -> dist/cli.js. This is what an incomplete
// `files` breaks, and the API would never notice.
const cli = join(nm, ".bin", "zbundle");
const cliEntry = readdirSync(join(nm, "zbundle", "dist")).includes("cli.js")
  ? join(nm, "zbundle", "dist", "cli.js")
  : null;
assert(cliEntry !== null, "dist/cli.js missing from the published package (incomplete `files`?)");
void cli;
execFileSync(process.execPath, [cliEntry, "./entry.js", "-o", "out-cli.mjs", "--quiet"], {
  cwd: witness,
  encoding: "utf8",
});
const cliRun = execFileSync(process.execPath, ["out-cli.mjs"], { cwd: witness, encoding: "utf8" });
assert(cliRun === EXPECT, `unexpected CLI output: ${JSON.stringify(cliRun)}`);
process.stdout.write("✔ CLI: the `zbundle` command bundles from the published package\n");

rmSync(witness, { recursive: true, force: true });
process.stdout.write("✔ prod rehearsal: the API AND the command start from the tarball\n");
