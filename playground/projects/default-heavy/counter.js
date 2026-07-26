// export default of a named class.
export default class Counter {
  constructor(start) {
    this.n = start;
  }
  next() {
    this.n += 1;
    return this.n;
  }
}
