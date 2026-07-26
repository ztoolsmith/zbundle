// The real world: lodash-es (hundreds of ESM modules, deep relative imports).
// We import 4 functions and check that the bundle computes THE SAME thing as
// the original modules.
import chunk from '../../../corpus/real/node_modules/lodash-es/chunk.js';
import camelCase from '../../../corpus/real/node_modules/lodash-es/camelCase.js';
import uniq from '../../../corpus/real/node_modules/lodash-es/uniq.js';
import sortBy from '../../../corpus/real/node_modules/lodash-es/sortBy.js';

const sample = [5, 3, 5, 1, 4, 1, 2];

console.log('chunk:', JSON.stringify(chunk(sample, 3)));
console.log('uniq:', JSON.stringify(uniq(sample)));
console.log('sortBy:', JSON.stringify(sortBy(sample)));
console.log('camelCase:', camelCase('zbundle est un bundler'));
console.log('compose:', JSON.stringify(chunk(uniq(sortBy(sample)), 2)));
