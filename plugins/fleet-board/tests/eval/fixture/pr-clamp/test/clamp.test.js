'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { clamp } = require('../src/clamp');

test('clamp returns n when it is within lo and hi', () => {
  assert.strictEqual(clamp(5, 0, 10), 5);
});

test('clamp returns lo when n is below lo', () => {
  assert.strictEqual(clamp(-3, 0, 10), 0);
});

test('clamp returns hi when n is above hi', () => {
  assert.strictEqual(clamp(15, 0, 10), 10);
});

test('clamp throws a RangeError when lo is greater than hi', () => {
  assert.throws(() => clamp(1, 10, 0), RangeError);
});
