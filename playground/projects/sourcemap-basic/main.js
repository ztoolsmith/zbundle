// expect-absent: unused
// expect-exports: label:function
// expect-call: label(4) -> 4 doubled is 8
// expect-sourcemap: label -> src/label.js
//
// The map covers every emitted statement, across three modules merged into one
// scope. The harness decodes the .map with the standard `source-map` library and
// walks the bundle line by line: each one must point back at a real position of
// the module it came from.
import { label } from './src/label.js';

console.log(label(4));
console.log(label(21));

export { label };
