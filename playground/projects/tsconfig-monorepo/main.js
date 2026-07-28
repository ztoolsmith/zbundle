// expect-exports: fromA:function fromB:function
// expect-call: fromA() -> a:A
// expect-call: fromB() -> b:B
//
// TWO tsconfigs, one per package, both mapping the SAME prefix `#own/` to their
// OWN `src`. A single global alias table cannot express that: whichever config
// was read first would win and one of the packages would silently import the
// other's module. Each alias is therefore SCOPED to its tsconfig's directory,
// and `resolver.zig` picks the nearest scope for each importing file.
//
// The two `tag()` values are deliberately different: if scoping were broken,
// both would answer the same letter and this project would fail loudly.
import { fromA } from '#pkg/a/index.js';
import { fromB } from '#pkg/b/index.js';

console.log(fromA(), fromB());

export { fromA, fromB };
