// expect-absent: dead
// expect-exports: greet:function
// expect-call: greet("world") -> hello world
//
// The paths come from a tsconfig this one EXTENDS, and they are written
// relative to that file (`../src/*`), not to this one. Getting that wrong is
// the classic extends bug, and it would show up as an unresolved import.
import { greet } from '#app/greet.js';

console.log(greet("world"));

export { greet };
