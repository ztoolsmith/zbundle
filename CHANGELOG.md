# Changelog

Toutes les modifications notables de zbundle. Format inspiré de
[Keep a Changelog](https://keepachangelog.com/fr/1.1.0/) ; versionnage
[SemVer](https://semver.org/lang/fr/).

## [0.1.0] — 2026-07-26

**La première version publiée.** Un bundler JavaScript/TypeScript écrit en Zig,
construit sur [zcompiler](https://github.com/ztoolsmith/zcompiler).

> **Note de numérotation** — le développement a traversé trois jalons internes
> (le graphe, le linking, le tree-shaking), suivis dans le journal du projet
> comme « v0.1 / v0.2 / v0.3 ». Rien n'ayant jamais été publié, ces numéros
> n'ont engagé personne : cette première release publique repart donc de
> **0.1.0**. Les jalons gardent leur nom dans le journal — ce sont des chantiers,
> pas des versions npm.

### Ce que ça fait

- **Résoudre** les specifiers relatifs : extensions omises dans un ordre qui est
  un contrat (`.ts` → `.tsx` → `.js` → `.jsx` → `.mjs`), résolution de dossier
  (`./utils` → `utils/index.ts`), chemins canoniques (liens symboliques, casse).
  Les specifiers **nus** (`react`, `lodash`) sont marqués **external** — la
  résolution `node_modules` est prévue plus tard.
- **Construire le graphe** : chaque module visité une fois, cycles détectés
  (Tarjan itératif), `import()` dynamique repéré, statistiques.
- **Compiler en amont** : TypeScript effacé, JSX abaissé en `jsx()/jsxs()` —
  toute la chaîne zcompiler, **avant** le linking (donc l'import de
  `react/jsx-runtime` injecté par le transform est visible du graphe).
- **Lier par scope hoisting** (la stratégie de rollup) : tous les modules
  fusionnés dans un seul scope, collisions résolues par renommage (`nom$1`), les
  `import` disparaissent (ce sont des alias de noms), les chaînes de re-export se
  résolvent jusqu'au binding d'origine, les namespaces sont matérialisés et
  dédupliqués, les externals hoistés et fusionnés en tête.
- **Secouer** (tree-shaking, mark & sweep) : n'émettre que l'atteignable depuis
  l'entry. Racines = les effets de bord top-level de chaque module + les exports
  de l'entry. Règle de pureté explicite et **conservatrice** — dans le doute,
  impur. `/* @__PURE__ */` reconnu.
- **La commande `zbundle`** : `-o`, `--format esm|iife`, `--dead`, `--graph`,
  `--watch`, `--quiet`. Le bundle sur stdout, les statistiques sur stderr.

### Ce que ça refuse (explicitement, plutôt qu'un bundle faux)

| refus | pourquoi |
|---|---|
| top-level await | rendrait le bundle entier asynchrone |
| `import.meta` | dépend de l'URL du module, qui n'existe plus après fusion |
| `import()` vers un module **interne** | demande un chunk séparé → code-splitting |
| live binding via un **objet namespace** | l'objet est un instantané : il figerait la valeur |
| `--format iife` avec des externals | un `import` est illégal dans une fonction |

Un live binding importé **nommément** fonctionne, lui : après fusion l'importeur
référence la même variable.

### Limites connues

- **`node_modules` n'est pas résolu.** Les imports de paquets deviennent des
  externals et restent dans le bundle. C'est la limite la plus visible : zbundle
  builde des bibliothèques, pas encore des applications.
- Pas de minification, pas de sourcemaps, pas de code-splitting, pas de CJS.
- Granularité du tree-shaking : le **statement top-level** (pas de découpe
  intra-statement, pas d'élimination de propriétés d'objet).
- Le backend **wasm** n'existe pas : le travail d'un bundler est de parcourir un
  système de fichiers, et `wasm32-freestanding` n'en a pas.

### Vérifié

68 tests Zig, 66 tests Node, **20/20** au juge (chaque projet est bundlé,
**exécuté**, et doit dire exactement ce que dit l'original ; le code mort est
vérifié absent textuellement ; les exports sont vérifiés par un
témoin-importeur), 12/12 fixtures de graphe, 3/3 projets-témoins.

Monde réel : **lodash-es, 172 modules, 131 → 81 Ko en ~30 ms**, résultats
identiques à l'original.

Plateformes : darwin-arm64, darwin-x64, linux-x64-gnu, linux-x64-musl,
linux-arm64-gnu, win32-x64-msvc.

[0.1.0]: https://github.com/ztoolsmith/zbundle/releases/tag/v0.1.0
