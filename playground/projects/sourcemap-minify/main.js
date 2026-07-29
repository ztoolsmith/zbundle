// expect-absent: computeTheAnswer
// expect-exports: answer:number
// expect-sourcemap: console -> main.js
// expect-sourcemap-name: a -> computeTheAnswer
//
// MINIFY AND SOURCEMAP TOGETHER. Every readable name is gone from the bundle —
// `computeTheAnswer` is `a` — and the map is the only thing that can say what
// `a` was. `expect-absent` proves the shortening really happened, so the name
// check is not passing by accident.
//
// The `export default` also matters here: the linker synthesizes a
// `const <name> =` for it, writing that line ITSELF rather than through the
// printer. Until 0.4.3 it carried no mapping at all — invisible while names were
// readable, and a dead end once minify turned it into a single letter.
import answer from './src/wrapped.js';

console.log('answer:', answer);

export { answer };
