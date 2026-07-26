// Imported ONLY for its effect: it exports nothing. The statement is impure ->
// a root -> it survives. That is the contract of `import './x'`.
globalThis.__PATCHED__ = true;

// This one is pure and nobody uses it: it must disappear.
export const neverUsedHelper = () => 'mort';
