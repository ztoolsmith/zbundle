const registry = [];
// Impur (un appel) : racine, meme si `registry` etait autrement inutilise.
registry.push('enregistre-a-l-import');

export const readRegistry = () => registry.join(',');
