// Un fichier TypeScript ordinaire : types, interface, enum, generiques.
// zbundle doit tout effacer et n'emettre que le JS.

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

// EXPORTEE depuis l'entry : c'est le contrat public du bundle, donc une RACINE.
// Elle survit meme si rien ne la reference — zero reference + export est le cas
// limite exact, et il est couvert par projects/export-unused/.
export function jamaisUtilisee(x: number): string {
  return `inutile ${x}`;
}

console.log(`${faites} faites, ${restantes} restante(s)`);
console.log('priorite max:', Priority.High);
