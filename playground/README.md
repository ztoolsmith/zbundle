# playground — le laboratoire

C'est ici que zbundle se teste **en l'exécutant**, pas seulement en le lisant.

## `run.mjs` — LE JUGE

```bash
node run.mjs                 # tout
node run.mjs diamond cycle   # ces projets seulement
node run.mjs --keep          # garde les .bundle.mjs générés, pour les lire
```

Pour chaque projet de `projects/` :

1. exécuter **l'original** dans Node → stdout de référence
2. **bundler** avec zbundle → un seul fichier
3. exécuter **le bundle** dans Node → stdout du bundle
4. **diff**. Identique = vert.

C'est le round-trip du bundler — le pendant exact du `parse ∘ print` de
zcompiler. Un bundler qui produit du code qui *tourne* mais dit autre chose est
un bundler cassé ; c'est la seule vérification qui ne peut pas se tromper
elle-même.

En bonus, gratuitement, sur chaque bundle : il **reparse** par zcompiler sans
erreur, passe le semantic sans diagnostic, et ne laisse **fuir aucun nom
interne** (tous ses `unresolved` sont des globals connus).

**Et depuis la v0.3**, le juge vérifie aussi le **tree-shaking**, via deux
en-têtes optionnels dans le `main.*` :

```js
// expect-absent: unused2 unused7 helperOfUnused
// expect-present: keptOne sharedHelper
```

C'est indispensable : un stdout identique prouve que rien de **vivant** n'a été
supprimé — il ne prouve pas que le **mort** a disparu.

### Le témoin-importeur

Exécuter le bundle comme un script **ignore ses `export`**. Un projet qui
déclare des exports fait donc générer un module qui **importe le bundle** et
vérifie son contrat :

```js
// expect-exports: jamaisUtilisee:function ns:object
// expect-call: jamaisUtilisee(42) -> inutile 42
```

`Object.keys` + `typeof` de chaque nom, puis **appel réel** de ceux qu'un
`expect-call` désigne (arguments en JSON). Les exports sont un contrat ; ils se
testent comme tel — pas par effet de bord.

Puis `refusals/` : chaque limite de la v0.2 **doit** produire une erreur, et une
erreur qui explique (≥ 2 lignes). Un bundle silencieusement faux serait pire
qu'un refus.

## `inspect.mjs` — l'œil

```bash
node inspect.mjs                  # liste les projets
node inspect.mjs barrel           # le bundle, en entier
node inspect.mjs barrel --graph   # + le graphe de modules
node inspect.mjs barrel --run     # + l'exécution
node inspect.mjs ../un/main.js    # n'importe quelle entry
```

Pour **comprendre ce que le linker a fait** : voir les collisions renommées
(`helper`, `helper$1`, `helper$2`), les namespaces matérialisés, les modules qui
n'émettent rien (un barrel pur), l'ordre topologique. Le pendant du debug
printer de zcompiler, qui montrait l'AST.

## Ajouter un cas — 30 secondes

```bash
mkdir projects/mon-cas
$EDITOR projects/mon-cas/main.js     # + les modules qu'il importe
node run.mjs mon-cas
```

**La seule règle** : `main.*` doit `console.log` un résultat **déterministe**
(pas d'horloge, pas d'aléatoire, pas d'ordre de `Set`/`Map` fragile). Le juge
compare deux stdout : tout ce qui varie d'un run à l'autre le fait échouer pour
de mauvaises raisons.

Pour un cas qui doit **échouer** :

```bash
mkdir refusals/mon-refus
echo '// expect-error: ce que zbundle doit refuser' > refusals/mon-refus/main.js
```

## Les projets

| projet | ce qu'il piège |
|---|---|
| `diamond` | le module partagé est évalué **une seule fois** (un compteur le prouve) |
| `cycle` | deux fonctions mutuellement récursives, à travers un cycle d'imports |
| `barrel` | re-exports en chaîne, `export * as ns`, `export *`, et **trois** `helper` en collision |
| `ts-jsx` | la chaîne zcompiler complète : types effacés + JSX abaissé, **avant** le linking |
| `external` | `node:fs`/`node:path` réels, importés par deux modules → un seul import |
| `default-heavy` | les trois formes d'`export default` (expression anonyme, classe, binding) |
| `live-binding` | un `export let` réassigné : le hoisting le gère **naturellement** |
| `real-lodash` | le monde réel — **172 modules** de lodash-es, résultats vérifiés |
| `shake-barrel` | **le cas d'école** : 1 fonction importée sur 20 → 24 modules deviennent 3 |
| `shake-sideeffect` | un module qui patche un global : importé pour son effet, il **survit** |
| `shake-diamond` | un diamant à moitié mort : le partagé survit, la branche morte tombe |
| `shake-class` | classe pure jamais instanciée (éliminée) vs champ statique impur (gardée) |
| `shake-star` | `export *` partiellement consommé |
| `shake-getter` | le piège : `obj.prop` peut être un getter, donc c'est conservé |
| `export-unused` | le cas limite : **exporté + zéro référence** survit, son jumeau privé meurt |
| `export-forms` | les **7 formes** d'export, toutes appelées à travers le bundle importé |

| refus | la limite v0.2 |
|---|---|
| `top-level-await` | rendrait le bundle entier asynchrone |
| `import-meta` | dépend de l'URL du module, qui n'existe plus après fusion |
| `dynamic-internal` | `import()` interne = un chunk séparé → c'est le code-splitting (v0.5) |
| `namespace-live` | l'objet namespace est un **snapshot** : il figerait un binding vivant |

## Aussi ici

- `index.js` — affiche le **graphe** d'une entry (l'outil de la v0.1).
- `corpus.js` — le harnais des fixtures `corpus/fixtures/` (`--graph`) et des
  projets-témoins (`--real`). Comparaison stricte à un `expected.json`.
