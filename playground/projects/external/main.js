import { readFileSync } from 'node:fs';
import { basename, join } from 'node:path';
import { encode } from './codec.js';
import { describe } from './describe.js';

console.log('basename:', basename('/a/b/c.txt'));
console.log('join:', join('a', 'b', '..', 'c'));
console.log('encode:', encode('zbundle'));
console.log('describe:', describe(readFileSync));
