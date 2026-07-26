// expect-error: live binding expose via un objet namespace
// LE cas ou le scope hoisting ne peut PAS reproduire ESM : l'objet namespace
// est construit une fois, il figerait la valeur.
import * as ns from './counter.js';
ns.bump();
console.log(ns.count);
