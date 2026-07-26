// expect-exports: inline:function nomme:function renomme:function default:function reexporte:function viaStar:function ns:object
// expect-call: inline(2) -> inline 2
// expect-call: nomme(3) -> nomme 3
// expect-call: renomme(4) -> renomme 4
// expect-call: default(5) -> default 5
// expect-call: reexporte(6) -> reexporte 6
// expect-call: viaStar(7) -> viaStar 7
//
// THE EXPORT FORMS, all exercised end to end by the importing witness. Before
// this project, no playground project exported anything at all: the linker's
// final `export { … }` was NEVER executed by the harness.

import { local } from './dep.js';

// 1. export <declaration> inline
export function inline(x) {
  return `inline ${x}`;
}

// 2. export { a } (specifiers)
function nomme(x) {
  return `nomme ${x}`;
}
// 3. export { a as b } (renamed)
function interne(x) {
  return `renomme ${x}`;
}
export { nomme, interne as renomme };

// 4. export default (an expression)
export default function (x) {
  return `default ${x}`;
}

// 5. export { x } from (re-export)
export { reexporte } from './dep.js';

// 6. export * from
export * from './star.js';

// 7. export * as ns from
export * as ns from './dep.js';

console.log('local:', local());
