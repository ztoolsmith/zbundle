import { basename } from 'node:path';
// Deux modules importent 'node:path' : le bundle ne doit produire QU'UN import.
export const encode = (s) => `${basename(s)}#${s.length}`;
