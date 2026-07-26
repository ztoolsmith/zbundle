// expect-absent: unused2 unused7 unused19 UNUSED_CONST helperOfUnused
// expect-present: keptOne sharedHelper
import { keptOne } from './lib/index.js';

console.log('utilise:', keptOne(21));
