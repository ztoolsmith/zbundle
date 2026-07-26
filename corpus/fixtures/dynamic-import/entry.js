import { eager } from './eager.js';

export async function load() {
  const lazy = await import('./lazy.js');
  return lazy.value + eager;
}

export const heavy = () => import('./heavy.ts');
export const vendor = () => import('some-vendor');

// Non analysable statiquement : aucune arete (rien a resoudre).
export const dyn = (name) => import(name);
