// expect-error: top-level await
const data = await Promise.resolve(42);
console.log(data);
