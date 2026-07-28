// expect-exports: render:function
// expect-call: render() -> span
// expect-sourcemap: render -> main.jsx
//
// THE FULL CHAIN: JSX lowered to jsx() by zcompiler, then hoisted and printed —
// and a position of the final JS still points at this file. The import that the
// transform INJECTS has no source at all, so it is deliberately left unmapped;
// everything that came from a real character is mapped.
const Badge = ({ label }) => <span>{label}</span>;

export const render = () => Badge({ label: 'x' }).type;

console.log('rendered:', render());
