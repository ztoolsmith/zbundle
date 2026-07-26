// Importe UNIQUEMENT pour son effet : il n'exporte rien. Le statement est
// impur -> racine -> il survit. C'est le contrat de `import './x'`.
globalThis.__PATCHED__ = true;

// Celle-ci est pure et personne ne l'utilise : elle doit disparaitre.
export const neverUsedHelper = () => 'mort';
