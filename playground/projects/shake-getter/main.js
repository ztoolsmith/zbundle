// expect-present: config
// The getter MUST run: its side effect is observable.
import { config } from './config.js';

console.log('config:', config);
console.log('getter appele', globalThis.__GETTER_CALLS__, 'fois');
