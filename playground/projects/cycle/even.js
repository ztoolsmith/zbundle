import { isOdd } from './odd.js';
export function isEven(n) {
  if (n === 0) return true;
  return isOdd(n - 1);
}
