// expect-present: __PATCHED__ registry.push
// expect-absent: neverUsedHelper
import './polyfill.js';
import { readRegistry } from './registry.js';

console.log('patched?', globalThis.__PATCHED__);
console.log('registry:', readRegistry());
