export class Used {
  constructor(n) { this.n = n; }
  double() { return this.n * 2; }
}
// A PURE class, never instantiated nor referenced: it disappears.
export class NeverUsed {
  constructor() { this.x = 1; }
}
