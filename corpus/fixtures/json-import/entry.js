// Import attributes (ES2025). The assets come from PACKAGES: the resolution
// table stops at .ts/.tsx/.js/.jsx/.mjs, so a relative './x.json' does not
// resolve (asset loaders come later). Bare specifiers, on the other hand, become
// externals — and the graph carries on.
import config from '@app/config/data.json' with { type: 'json' };
import 'normalize.css/normalize.css' with { type: 'css' };
import * as data from 'vendor-data' with { type: 'json' };

export { entries } from 'vendor-entries' with { type: 'json' };
export * as legacy from 'vendor-legacy' assert { type: 'json' };

// And real local code alongside, which must be followed normally.
import { code } from './code.js';
export const out = { config, data, code };
