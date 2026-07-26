// expect-present: jamaisUtilisee
// expect-absent: jamaisUtiliseePrivee
// expect-exports: jamaisUtilisee:function
// expect-call: jamaisUtilisee(42) -> inutile 42
//
// LE CAS LIMITE des racines du tree-shaking : une fonction EXPORTEE par l'entry
// et JAMAIS referencee en interne. Zero reference + export — elle doit survivre,
// parce que les exports de l'entry sont le contrat public du bundle.
//
// Son jumeau non exporte, lui, doit mourir : le fix ne doit pas SUR-marquer.

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

// EXPORTEE, zero reference -> RACINE, elle survit.
export function jamaisUtilisee(x: number): string {
  return `inutile ${x}`;
}

// PAS exportee, zero reference -> inatteignable, elle meurt.
function jamaisUtiliseePrivee(x: number): string {
  return `prive ${x}`;
}

console.log(`${faites} faites, ${restantes} restante(s)`);
console.log('priorite max:', Priority.High);
