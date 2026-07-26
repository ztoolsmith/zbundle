import greet from './greet.js';
import Counter from './counter.js';
import config from './config.js';
import { named } from './greet.js';

const c = new Counter(3);
console.log(greet('world'));
console.log('named:', named);
console.log('counter:', c.next(), c.next(), c.next());
console.log('config:', config.name, config.level);
