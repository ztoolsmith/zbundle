// expect-absent: unused
// expect-exports: label:function
// expect-call: label(2, 3) -> 2 + 3 = 5
//
// THE ALIAS, judged honestly. Node resolves `#lib/*` through the `imports` field
// of this project's package.json; zbundle resolves the SAME specifier through
// `resolve.alias`. So the original and the bundle can be compared: both really
// run, and any divergence is the alias getting it wrong.
import { label } from '#lib/label.js';

console.log(label(2, 3));
console.log(label(10, 32));

// Re-exported so the importing witness can call it THROUGH the bundle the
// command produced: an aliased import must survive as a real export.
export { label };
