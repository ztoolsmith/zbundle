import { add, mul, VERSION, strings } from './lib/index.js';
import { format } from './format.js';

console.log(format('add', add(2, 3)));
console.log(format('mul', mul(2, 3)));
console.log(format('upper', strings.upper('zbundle')));
console.log(format('repeat', strings.repeat('ab', 3)));
console.log('version:', VERSION);
