// export default <expression anonyme> : le linker doit lui fabriquer un nom.
const prefix = 'hello';
export default function (who) {
  return `${prefix}, ${who}!`;
}
export const named = 'from-greet';
