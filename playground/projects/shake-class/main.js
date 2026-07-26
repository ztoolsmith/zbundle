// expect-absent: NeverUsed
// expect-present: RegistersItself Used
import { Used } from './used.js';
import './registers.js';

console.log('utilisee:', new Used(4).double());
console.log('registre:', globalThis.__CLASS_REGISTRY__);
