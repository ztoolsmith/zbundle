// Le monde reel des la v0.2 : lodash-es (des centaines de modules ESM, imports
// relatifs profonds). On importe 4 fonctions et on verifie que le bundle
// calcule LA MEME chose que les modules d'origine.
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
