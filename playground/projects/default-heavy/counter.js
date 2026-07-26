// export default d'une classe nommee.
export default class Counter {
  constructor(start) {
    this.n = start;
  }
  next() {
    this.n += 1;
    return this.n;
  }
}
