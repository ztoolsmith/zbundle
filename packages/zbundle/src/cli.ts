#!/usr/bin/env node
//! La commande `zbundle` : bundler depuis un terminal, sans écrire de glue.
//!
//! Tout le travail est dans l'addon (`../index.js`). Ce fichier ne fait que
//! trois choses, et c'est voulu :
//!   1. lire des arguments,
//!   2. écrire le résultat quelque part,
//!   3. **présenter les refus** — la partie qui compte vraiment. Un bundler qui
//!      refuse doit dire quoi faire, et le dire lisiblement.
import { parseArgs } from "node:util";
import { writeFileSync, watch, existsSync, statSync } from "node:fs";
import { dirname, resolve, relative } from "node:path";
import process from "node:process";

import { bundleWith, graphPrint, VERSION } from "../index.js";

const HELP = `zbundle — bundler JavaScript/TypeScript ecrit en Zig

Usage:
  zbundle <entry> [-o <fichier>]      Bundler (ESM, un seul fichier)
  zbundle <entry> --graph             Afficher le graphe de modules, sans bundler
  zbundle <entry> --dead              Bundler + lister ce que le tree-shaking a elimine
  zbundle <entry> --watch -o <f>      Rebundler a chaque changement

Options:
  -o, --out <fichier>   Ecrire ici (defaut : la sortie standard)
  -f, --format <fmt>    esm (defaut) | iife  — iife exige zero dependance externe
      --dead            Lister le code elimine (module, ligne, raison)
      --graph           Le graphe de modules au lieu du bundle
      --watch           Reconstruire quand un module change (avec -o)
      --quiet           Pas de statistiques
  -h, --help            Cette aide
  -v, --version         La version

Les statistiques vont sur la sortie d'ERREUR : \`zbundle src/index.js > out.js\`
donne un fichier propre, et les chiffres restent lisibles a l'ecran.
`;

// Couleurs seulement si on parle a un terminal (sinon on pollue les pipes).
const tty = process.stderr.isTTY === true;
const c = (code: string, s: string) => (tty ? `\x1b[${code}m${s}\x1b[0m` : s);
const bold = (s: string) => c("1", s);
const dim = (s: string) => c("2", s);
const red = (s: string) => c("31", s);
const green = (s: string) => c("32", s);

interface Stats {
  modules: number;
  modules_dropped: number;
  externals: number;
  renamed: number;
  statements_kept: number;
  statements_dropped: number;
  entry_exports: number;
  input_bytes: number;
  output_bytes: number;
  bundle_ms: number;
}

function fail(message: string): never {
  process.stderr.write(`${red("✘")} ${message.replace(/\n/g, "\n  ")}\n`);
  process.exit(1);
}

/** Les chiffres, en une ligne dense mais lisible. */
function reportStats(s: Stats, out: string | undefined, format: string): void {
  const pct = s.input_bytes > 0 ? ((100 * s.output_bytes) / s.input_bytes).toFixed(0) : "0";
  // Le plus court des deux : un chemin relatif truffé de `../..` est illisible.
  const rel = out ? relative(process.cwd(), out) : "";
  const where = out ? (rel.length < out.length ? rel : out) : "(stdout)";
  const shaken =
    s.statements_dropped > 0
      ? dim(`  −${s.statements_dropped} statements, −${s.modules_dropped} modules`)
      : "";
  process.stderr.write(
    `${green("✔")} ${bold(where)}  ${s.modules} modules  ${s.externals} externals${shaken}\n` +
      `  ${s.input_bytes} → ${s.output_bytes} octets (${pct} %) en ${s.bundle_ms.toFixed(2)} ms  ${dim(format)}\n`,
  );
  // Une IIFE n'exporte rien : si l'entry exportait, on le DIT.
  if (format === "iife" && s.entry_exports > 0) {
    process.stderr.write(
      dim(`  note : ${s.entry_exports} export(s) de l'entry perdus — une IIFE n'exporte rien\n`),
    );
  }
}

interface Dead {
  module: string;
  line: number;
  snippet: string;
  reason: string;
}

/** Ce que le tree-shaking a retiré, groupé par module. */
function reportDead(dead: Dead[]): void {
  if (dead.length === 0) {
    process.stderr.write(dim("  (rien elimine : tout etait atteignable)\n"));
    return;
  }
  const byModule = new Map<string, Dead[]>();
  for (const d of dead) {
    const list = byModule.get(d.module) ?? [];
    list.push(d);
    byModule.set(d.module, list);
  }
  process.stderr.write(`\n${bold("elimine par le tree-shaking")}\n`);
  for (const [mod, list] of byModule) {
    process.stderr.write(`  ${mod}\n`);
    for (const d of list) {
      process.stderr.write(`    ${dim(`L${d.line}`)} ${d.snippet}\n`);
      process.stderr.write(`       ${dim(`↳ ${d.reason}`)}\n`);
    }
  }
}

/**
 * Un build. Renvoie les chemins des modules, pour --watch.
 *
 * **Ne quitte pas le process** : c'est l'appelant qui décide. En one-shot une
 * erreur est fatale ; en `--watch` elle ne l'est surtout pas — on affiche, on
 * garde la main, et le prochain enregistrement relance.
 */
function build(entry: string, opts: { out?: string; format: string; dead: boolean; quiet: boolean }): string[] {
  const result = bundleWith(entry, { format: opts.format, dead: opts.dead }) as {
    code: string;
    stats: Stats;
    dead: Dead[];
  };

  if (opts.out) writeFileSync(opts.out, result.code);
  else process.stdout.write(result.code);

  if (!opts.quiet) reportStats(result.stats, opts.out, opts.format);
  if (opts.dead) reportDead(result.dead);

  // Les modules réellement lus, pour savoir quoi surveiller.
  return modulesOf(entry);
}

/** Les chemins des modules du graphe (pour --watch). */
function modulesOf(entry: string): string[] {
  try {
    // `graphPrint` est déjà là ; on n'ajoute pas d'API pour si peu. Les chemins
    // affichés sont relatifs au dossier de l'entry.
    const root = dirname(entry);
    return graphPrint(entry)
      .split("\n")
      .map((l) => l.trim().replace(/\s+\(.*\)$/, ""))
      .filter((l) => l.startsWith("./"))
      .map((l) => resolve(root, l))
      .filter((p) => existsSync(p) && statSync(p).isFile());
  } catch {
    return [entry];
  }
}

function main(): void {
  const { values, positionals } = parseArgs({
    args: process.argv.slice(2),
    allowPositionals: true,
    options: {
      out: { type: "string", short: "o" },
      format: { type: "string", short: "f", default: "esm" },
      dead: { type: "boolean", default: false },
      graph: { type: "boolean", default: false },
      watch: { type: "boolean", default: false },
      quiet: { type: "boolean", default: false },
      help: { type: "boolean", short: "h", default: false },
      version: { type: "boolean", short: "v", default: false },
    },
  });

  if (values.help) {
    process.stdout.write(HELP);
    return;
  }
  if (values.version) {
    process.stdout.write(`${VERSION}\n`);
    return;
  }
  if (positionals.length === 0) {
    process.stderr.write(HELP);
    process.exit(1);
  }
  if (positionals.length > 1) {
    fail(`une seule entry a la fois (recu : ${positionals.join(", ")})`);
  }

  const entry = resolve(positionals[0]!);
  if (!existsSync(entry)) fail(`entry introuvable : ${positionals[0]}`);

  if (values.graph) {
    process.stdout.write(graphPrint(entry));
    return;
  }

  const out = values.out ? resolve(values.out) : undefined;
  const opts = { out, format: values.format!, dead: values.dead!, quiet: values.quiet! };

  if (!values.watch) {
    try {
      build(entry, opts);
    } catch (err) {
      // LE moment qui compte : les refus de zbundle disent quoi faire. On les
      // réémet tels quels, sans les reformater.
      fail(err instanceof Error ? err.message : String(err));
    }
    return;
  }

  // --watch : sans -o on écrirait le bundle dans le terminal à chaque frappe.
  if (!out) fail("--watch demande -o <fichier> (sinon le bundle part dans le terminal)");

  /** Un build de watch : jamais fatal, on garde la main quoi qu'il arrive. */
  const attempt = (): string[] => {
    try {
      return build(entry, opts);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      process.stderr.write(`${red("✘")} ${message.replace(/\n/g, "\n  ")}\n`);
      return watched; // on continue de surveiller les mêmes fichiers
    }
  };

  let watched = modulesOf(entry);
  watched = attempt();
  let timer: NodeJS.Timeout | undefined;
  const rebuild = () => {
    clearTimeout(timer);
    // Un éditeur écrit souvent en plusieurs fois : on laisse retomber.
    timer = setTimeout(() => {
      process.stderr.write(dim(`\n— rebuild ${new Date().toLocaleTimeString()}\n`));
      watched = attempt();
      rearm();
    }, 30);
  };

  let watchers: ReturnType<typeof watch>[] = [];
  const rearm = () => {
    for (const w of watchers) w.close();
    watchers = watched.map((p) => watch(p, rebuild));
  };
  rearm();
  process.stderr.write(dim(`— watch : ${watched.length} modules surveilles (Ctrl-C pour arreter)\n`));
}

try {
  main();
} catch (err) {
  fail(err instanceof Error ? err.message : String(err));
}
