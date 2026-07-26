// expect-error: live binding exposed through a namespace object
// THE case where scope hoisting CANNOT reproduce ESM: the namespace object is
// built once, so it would freeze the value.
import * as ns from './counter.js';
ns.bump();
console.log(ns.count);
