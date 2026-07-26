import { sharedUtil } from './shared.js';
import { heavyDependency } from './heavy.js';
export const deadBranch = (n) => sharedUtil(n) + heavyDependency(n);
