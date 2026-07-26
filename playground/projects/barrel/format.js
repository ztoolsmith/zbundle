// Deliberate collision: `helper` ALSO exists in lib/math.js and lib/strings.js.
const helper = (k) => `[${k}]`;
export const format = (k, v) => `${helper(k)} ${v}`;
