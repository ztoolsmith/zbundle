// expect-absent: unused
// expect-exports: label:function
// expect-call: label(4, 5) -> 4 + 5 = 9
//
// THE TWIN of `config-alias`, resolved from a tsconfig instead. Node resolves
// `#lib/*` through this project's `imports` field; zbundle resolves the same
// specifier through the tsconfig's `paths`. Neither the config nor the harness
// mentions an alias — the tsconfig alone has to do the work.
import { label } from '#lib/label.js';

console.log(label(4, 5));
console.log(label(20, 22));

export { label };
