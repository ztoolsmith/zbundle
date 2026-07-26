import { basename } from 'node:path';
// Two modules import 'node:path': the bundle must produce ONLY ONE import.
export const encode = (s) => `${basename(s)}#${s.length}`;
