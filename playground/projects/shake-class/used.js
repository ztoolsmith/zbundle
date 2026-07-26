export class Used {
  constructor(n) { this.n = n; }
  double() { return this.n * 2; }
}
// Classe PURE et jamais instanciee ni referencee : elle disparait.
export class NeverUsed {
  constructor() { this.x = 1; }
}
