# zbundle

Un bundler JavaScript/TypeScript écrit en **Zig**, construit sur
[zcompiler](../zcompiler) (le compilateur) et [zignapi](../zignapi) (le pont Node).

**v0.3 — le tree-shaking.** `zbundle.bundle(entry)` rend un seul fichier de JS
exécutable (format ESM) qui ne contient **que le code atteignable depuis
l'entry**. Par **scope hoisting** : tous les modules fusionnés dans un scope, les
collisions résolues par renommage. Pas de wrappers de fonctions, pas de registre
à l'exécution — du JS plat et lisible.

> Importer 1 fonction d'un barrel de 20 : **24 modules / 4022 o → 3 modules / 260 o**.

```js
import zbundle from "zbundle";

zbundle.bundle("src/index.tsx"); // -> une string de JS
```

```js
// Genere par zbundle — format ESM, un seul fichier.
import { jsx } from 'react/jsx-runtime';

// ── lib/math.js ──
const helper = (n) => n;
const add = (a, b) => helper(a) + helper(b);

// ── format.js ──
const helper$1 = (k) => `[${k}]`;          // collision renommée
const format = (k, v) => `${helper$1(k)} ${v}`;

// ── main.js ──
console.log(format('add', add(2, 3)));
```

Le juge : **le bundle tourne dans Node et dit exactement ce que dit le projet
d'origine** (`playground/run.mjs`) — le round-trip du bundler.

## Ce que la v0.2 sait faire

- **Résoudre** les specifiers relatifs : extensions omises
  (`.ts` → `.tsx` → `.js` → `.jsx` → `.mjs`, dans cet ordre), résolution de
  dossier (`./utils` → `utils/index.ts`), chemins canoniques (symlinks, casse).
- **Traverser et ordonner** : chaque module une seule fois, émis après ses
  dépendances (post-ordre DFS) ; les cycles détectés et gérés.
- **Compiler en amont** : TypeScript effacé, JSX abaissé en `jsx()/jsxs()` —
  toute la chaîne zcompiler, avant le linking.
- **Lier** : les `import` disparaissent (ce sont des alias de noms), les chaînes
  de re-export se résolvent jusqu'au binding d'origine, les namespaces
  (`import * as ns`) sont matérialisés et dédupliqués, les externals hoistés et
  fusionnés en tête, les exports de l'entry sont les seuls survivants.
- **Secouer** : n'émettre que l'atteignable. Les racines sont les effets de bord
  top-level (un module importé EST évalué) et les exports de l'entry ; tout le
  reste doit se justifier. La règle de pureté est explicite et conservatrice —
  **dans le doute, impur** : un bundle 5 % plus gros est un bug de moins.
- **Refuser clairement** ce qu'il ne peut pas faire honnêtement (cf. plus bas).

## Démarrer

```bash
pnpm install
pnpm build     # compile l'addon + génère index.js / index.d.ts
pnpm test      # node --test

node playground/run.mjs                       # LE JUGE
node playground/inspect.mjs barrel --run      # lire un bundle, et l'exécuter
node playground/inspect.mjs shake-diamond --dead  # ce que le shaking a éliminé
```

Prérequis : Zig **0.16.0**, Node ≥ 18, et les repos `zignapi` + **`zcompiler`
≥ 0.3.0** clonés à côté (zbundle les référence en siblings).

## Les limites de la v0.2 (refusées, jamais devinées)

| refus | pourquoi |
|---|---|
| top-level await | rendrait le bundle entier asynchrone |
| `import.meta` | dépend de l'URL du module, qui n'existe plus après fusion |
| `import()` vers un module **interne** | demande un chunk séparé → code-splitting (v0.5) |
| live binding via un **objet namespace** | l'objet est un snapshot : il figerait la valeur |

Un live binding importé **nommément** (`export let` réassigné) fonctionne, lui,
naturellement : après fusion l'importeur référence la même variable.

## État

| | |
|---|---|
| tests Zig | 59 |
| tests Node | 52 |
| playground (le juge) | **18/18** — le bundle dit ce que dit l'original, et le code mort est absent |
| fixtures de graphe | 12/12 |
| projets-témoins | 3/3 |
| monde réel | **lodash-es : 172 modules, 131 → 81 Ko, 30 ms**, résultats identiques |

## Feuille de route

- **v0.4** — la minification cross-module (le mangler de zcompiler existe déjà),
  puis les sourcemaps.
- **v0.5** — `node_modules` (la vraie résolution de paquets, et le champ
  `sideEffects` qui va avec) et le code-splitting (les arêtes `is_dynamic` sont
  déjà dans le graphe).
- plus tard — top-level await, granularité intra-statement.

MIT.
