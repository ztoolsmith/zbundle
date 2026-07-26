// expect-error: dynamic import() of an internal module
export async function load() {
  const m = await import('./lazy.js');
  return m.value;
}
