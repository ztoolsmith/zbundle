# corpus/real — les projets-temoins

Les fixtures (`../fixtures/`) sont fabriquées : elles testent UN aspect chacune,
avec un `expected.json` exact. Ici c'est l'inverse — du **vrai code**, qu'on
n'a pas écrit, où l'on vérifie seulement ce qui est vérifiable sans oracle :

- le graphe **se construit** (zéro crash, zéro boucle infinie) ;
- les stats sont **plausibles** (le nombre de modules, d'arêtes, de cycles) ;
- zéro erreur de parse (sinon c'est zcompiler qui a un trou, pas zbundle).

`node_modules/` est **gitignoré** (même convention que `corpus/` chez
zcompiler). Pour le peupler :

```bash
cd corpus/real && npm install
```

`lodash-es` est la pièce maîtresse : ~640 modules ESM, tous en imports relatifs
avec extension explicite, et un `lodash.js` qui re-exporte tout le paquet — un
graphe large ET profond, exactement ce qu'un bundler doit avaler.
