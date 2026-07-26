// Le module partage : s'il etait emis deux fois, `times` vaudrait 2 et les
// deux objets `counter` seraient distincts. C'est LE test de la deduplication.
export const base = 10;
export const counter = { times: 0 };
counter.times += 1;
