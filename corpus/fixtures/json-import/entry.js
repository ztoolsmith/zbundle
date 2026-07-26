// Import attributes (ES2025). Les assets viennent de PAQUETS : en v0.1 la table
// de résolution s'arrête à .ts/.tsx/.js/.jsx/.mjs, donc un './x.json' relatif ne
// résout pas (les loaders d'assets, c'est la v0.5). Les specifiers nus, eux,
// deviennent des externals — et le graphe continue.
import config from '@app/config/data.json' with { type: 'json' };
import 'normalize.css/normalize.css' with { type: 'css' };
import * as data from 'vendor-data' with { type: 'json' };

export { entries } from 'vendor-entries' with { type: 'json' };
export * as legacy from 'vendor-legacy' assert { type: 'json' };

// Et du vrai code local à côté, qui doit être suivi normalement.
import { code } from './code.js';
export const out = { config, data, code };
