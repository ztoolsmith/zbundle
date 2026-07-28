// expect-absent: 'react/jsx-runtime'
// expect-present: 'preact/jsx-runtime'
// expect-exports: render:function
// expect-call: render() -> preact
//
// `jsxImportSource` read from the tsconfig and handed to zcompiler. The check
// that matters is textual AND behavioural: the emitted import names preact, and
// calling the exported component returns the marker only THIS runtime sets.
//
// The quotes in the two headers above are load-bearing: `preact/jsx-runtime`
// CONTAINS `react/jsx-runtime`, so an unquoted absence check would fail on a
// perfectly correct bundle.
const Badge = ({ label }) => <span>{label}</span>;

export const render = () => Badge({ label: 'x' }).runtime;

console.log('runtime:', render());
