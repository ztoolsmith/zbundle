import { fromB } from './b.js';
import { fromC } from './c.js';
import { counter } from './shared.js';

console.log('b:', fromB());
console.log('c:', fromC());
console.log('shared evalue', counter.times, 'fois');
console.log('somme:', fromB() + fromC());
