// expect-present: jamaisUtilisee
// expect-absent: jamaisUtiliseePrivee
// expect-exports: jamaisUtilisee:function
// expect-call: jamaisUtilisee(42) -> inutile 42
//
// THE EDGE CASE of tree-shaking roots: a function EXPORTED by the entry and
// NEVER referenced internally. Zero references + exported — it must survive,
// because the entry's exports are the bundle's public contract.
//
// Its non-exported twin must die: marking must not OVER-mark.

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

// EXPORTED, zero references -> a ROOT, it survives.
export function jamaisUtilisee(x: number): string {
  return `inutile ${x}`;
}

// NOT exported, zero references -> unreachable, it dies.
function jamaisUtiliseePrivee(x: number): string {
  return `prive ${x}`;
}

console.log(`${faites} faites, ${restantes} restante(s)`);
console.log('priorite max:', Priority.High);
