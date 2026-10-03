'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { add } = require('../src/calc.js');

test('add(2, 3) returns 5', () => {
  assert.equal(add(2, 3), 5);
});
