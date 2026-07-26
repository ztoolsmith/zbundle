// Live binding: `count` is REASSIGNED. Scope hoisting handles it NATURALLY
// (after merging, the importer references THE SAME variable).
import { bump, count } from './counter.js';
bump();
console.log(count);
console.log('encore:', count);
