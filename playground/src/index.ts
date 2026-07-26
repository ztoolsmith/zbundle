// An ordinary TypeScript file: types, interface, enum, generics.
// zbundle must erase it all and emit only the JS.

interface Task {
  id: number;
  label: string;
  done: boolean;
}

enum Priority {
  Low = 1,
  High = 10,
}

type Filter<T> = (item: T) => boolean;

const tasks: Task[] = [
  { id: 1, label: 'ecrire le linker', done: true },
  { id: 2, label: 'ecrire le tree-shaking', done: true },
  { id: 3, label: 'resoudre node_modules', done: false },
];

function count<T>(items: readonly T[], keep: Filter<T>): number {
  return items.filter(keep).length;
}

const faites = count(tasks, (t: Task) => t.done);
const restantes = count(tasks, (t: Task) => !t.done);

// EXPORTED from the entry: this is the bundle's public contract, hence a ROOT.
// It survives even if nothing references it — zero references + exported is the
// exact edge case, covered by projects/export-unused/.
export function jamaisUtilisee(x: number): string {
  return `inutile ${x}`;
}

console.log(`${faites} faites, ${restantes} restante(s)`);
console.log('priorite max:', Priority.High);
