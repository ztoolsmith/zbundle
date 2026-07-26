// The shared module: if it were emitted twice, `times` would be 2 and the two
// `counter` objects would be distinct. THE deduplication test.
export const base = 10;
export const counter = { times: 0 };
counter.times += 1;
