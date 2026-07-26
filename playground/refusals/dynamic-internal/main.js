// expect-error: import() dynamique vers un module interne
export async function load() {
  const m = await import('./lazy.js');
  return m.value;
}
