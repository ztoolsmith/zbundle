// expect-error: dynamic import() of an internal module
// expect-codeframe: import('./lazy.js')
export async function load() {
  const m = await import('./lazy.js');
  return m.value;
}
