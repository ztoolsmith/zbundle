// Répétition générale de la publication : `npm pack` le paquet principal + le
// paquet de plateforme de l'hôte dans un témoin VIDE, puis on prouve que le
// paquet PUBLIÉ démarre — pas celui du dépôt.
//
// zbundle a DEUX surfaces, et les deux se cassent différemment :
//   1. l'API      : `require("zbundle").bundle(entry)`
//   2. la COMMANDE : `zbundle <entry>` via le champ `bin`
// Une release qui oublie `dist/` dans `files` casse la 2ᵉ sans toucher la 1ʳᵉ.
// Un `prepublish` oublié casse les deux. On teste donc les deux.
//
// À lancer depuis le dossier du paquet, APRÈS `zignapi build` (+ `--target
// <triple-hôte>`) et `zignapi prepublish`.
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import process from "node:process";

const PKG = process.cwd();

/** Le triple napi-rs de l'hôte (doit correspondre à un npm/<triple>/ construit). */
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
  execFileSync("cp", ["-R", join(tmp, "package") + "/.", targetDir]); // npm emballe dans `package/`
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
  throw new Error(`pas de npm/${triple}/ — lancer \`zignapi build --target ${triple}\` d'abord`);
}

const witness = mkdtempSync(join(tmpdir(), "zb-witness-"));
const nm = join(witness, "node_modules");
const scope = join(nm, "@zbundle");
mkdirSync(scope, { recursive: true });

extractInto(pack(PKG, witness), join(nm, "zbundle"));
extractInto(pack(join(PKG, "npm", triple), witness), join(scope, `binding-${triple}`));

// Un mini-projet à bundler DANS le témoin : deux modules, une collision de nom,
// et un module mort — de quoi exercer le linking ET le tree-shaking.
writeFileSync(
  join(witness, "dep.js"),
  "const helper = (n) => n + 1;\nexport const vivant = (n) => helper(n) * 2;\nexport const mort = () => 'jamais';\n",
);
writeFileSync(
  join(witness, "entry.js"),
  "import { vivant } from './dep.js';\nconst helper = () => 'local';\nconsole.log(vivant(20), helper());\n",
);

const EXPECT = "42 local\n";

// 1. L'API : require("zbundle") → bindings.js → le paquet de plateforme.
const api = execFileSync(
  process.execPath,
  ["-e", `const z=require("zbundle");require("node:fs").writeFileSync("out-api.mjs",z.bundle("./entry.js"))`],
  { cwd: witness, encoding: "utf8" },
);
void api;
const apiRun = execFileSync(process.execPath, ["out-api.mjs"], { cwd: witness, encoding: "utf8" });
assert(apiRun === EXPECT, `sortie de l'API inattendue : ${JSON.stringify(apiRun)}`);
process.stdout.write("✔ API : require(\"zbundle\").bundle() → un bundle qui s'execute\n");

// Le tree-shaking a bien mordu dans le paquet publié (pas seulement en dev).
const code = execFileSync(
  process.execPath,
  ["-e", `process.stdout.write(require("zbundle").bundle("./entry.js"))`],
  { cwd: witness, encoding: "utf8" },
);
assert(!code.includes("mort"), "le tree-shaking n'a pas retire `mort` dans le paquet publie");
assert(code.includes("helper$1") || code.includes("helper"), "le renommage cross-module a disparu");
process.stdout.write("✔ tree-shaking + renommage actifs depuis le paquet publie\n");

// 2. La COMMANDE : le champ `bin` → dist/cli.js. C'est ce que casse un `files`
// incomplet, et l'API ne s'en apercevrait pas.
const cli = join(nm, ".bin", "zbundle");
const cliEntry = readdirSync(join(nm, "zbundle", "dist")).includes("cli.js")
  ? join(nm, "zbundle", "dist", "cli.js")
  : null;
assert(cliEntry !== null, "dist/cli.js absent du paquet publie (champ `files` incomplet ?)");
void cli;
execFileSync(process.execPath, [cliEntry, "./entry.js", "-o", "out-cli.mjs", "--quiet"], {
  cwd: witness,
  encoding: "utf8",
});
const cliRun = execFileSync(process.execPath, ["out-cli.mjs"], { cwd: witness, encoding: "utf8" });
assert(cliRun === EXPECT, `sortie du CLI inattendue : ${JSON.stringify(cliRun)}`);
process.stdout.write("✔ CLI : la commande `zbundle` bundle depuis le paquet publie\n");

rmSync(witness, { recursive: true, force: true });
process.stdout.write("✔ prod simulee : l'API ET la commande demarrent depuis le tarball\n");
