// expect-absent: deadBranch heavyDependency
// expect-present: liveBranch sharedUtil
import { liveBranch } from './index.js';

console.log('resultat:', liveBranch(10));
