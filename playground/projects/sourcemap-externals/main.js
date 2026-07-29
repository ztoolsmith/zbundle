// expect-exports: run:function
// expect-call: run() -> [HELLO]
// expect-sourcemap: decorate -> src/helper.js
//
// A HOISTED PRELUDE sits above every module body: `import { stamp } from
// 'tiny-dep'` is emitted first, before any statement of any module. Every
// mapping below it must still land on the right character — the classic way a
// naive implementation drifts by exactly the height of what it prepended.
//
// It holds here by construction rather than by arithmetic: the printer writes
// its offsets into the bundle's own buffer, which already contains the prelude
// by the time module bodies are printed.
import { stamp } from 'tiny-dep';
import { decorate } from './src/helper.js';

export const run = () => stamp(decorate('hello'));

console.log(run());
