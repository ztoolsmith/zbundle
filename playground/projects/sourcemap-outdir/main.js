// expect-exports: run:function
// expect-call: run() -> 21
// expect-sourcemap: triple -> src/deep/math.js
//
// The map does NOT sit beside the config: `output.dir` is two levels deep, so
// every `sources` entry has to climb back out. Resolving them against the cwd
// instead would leave them unchanged and silently point at nothing — the map
// still parses, the debugger just opens the wrong file.
//
// The judge resolves `triple` back through the map and checks the line it lands
// on really contains it, which is what makes a wrong depth visible.
import { triple } from './src/deep/math.js';

export const run = () => triple(7);

console.log(run());
