// expect-present: config
// Le getter DOIT s'executer : son effet de bord est observable.
import { config } from './config.js';

console.log('config:', config);
console.log('getter appele', globalThis.__GETTER_CALLS__, 'fois');
