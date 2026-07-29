// expect-exports: both:function
// expect-call: both() -> left+left|right
// expect-sourcemap: both -> main.js
// expect-sourcemap-name: shared$1 -> shared
//
// TWO modules export the same name, so the linker renames one of them. The
// renamed one is used three times inside its own module — declaration plus two
// references — and EVERY occurrence must lead back to the `shared` written in
// `src/left.js`.
//
// Renaming replaces a node's TEXT, never its span, so the position was already
// right in 0.4.0. What 0.4.1 adds is the NAME: a debugger showing `shared$1`
// leaves you guessing which of the two modules it came from.
//
// Note what the "original name" means here: it is the identifier AS WRITTEN AT
// THAT SOURCE POSITION. An aliased import (`import { shared as x }`) therefore
// carries `x` on its references — that is what the developer typed in the
// importing file, and what a debugger should show them.
import { twice } from './src/left.js';
import { shared as fromRight } from './src/right.js';

export const both = () => `${twice()}|${fromRight()}`;

console.log(both());
