// expect-absent: fromB fromC unusedFromA
// expect-present: fromA
import { fromA } from './all.js';

console.log('a:', fromA());
