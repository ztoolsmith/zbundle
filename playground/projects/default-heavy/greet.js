// export default <anonymous expression>: the linker must synthesize a name for it.
const prefix = 'hello';
export default function (who) {
  return `${prefix}, ${who}!`;
}
export const named = 'from-greet';
