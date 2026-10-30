'use strict';

function clamp(n, lo, hi) {
  if (lo > hi) throw new RangeError('lo must not exceed hi');
  if (n < lo) return lo;
  if (n > hi) return hi;
  return n;
}

module.exports = { clamp };
