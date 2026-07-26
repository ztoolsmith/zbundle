import { isEven } from './even.js';
export function isOdd(n) {
  if (n === 0) return false;
  return isEven(n - 1);
}
