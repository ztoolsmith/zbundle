const registry = [];
// Impure (a call): a root, even if `registry` were otherwise unused.
registry.push('enregistre-a-l-import');

export const readRegistry = () => registry.join(',');
