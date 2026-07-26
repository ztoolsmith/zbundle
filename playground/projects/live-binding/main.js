// Live binding : `count` est REASSIGNE. Le scope hoisting le gere
// NATURELLEMENT (apres fusion, l/importeur reference LA MEME variable).
import { bump, count } from './counter.js';
bump();
console.log(count);
console.log('encore:', count);
