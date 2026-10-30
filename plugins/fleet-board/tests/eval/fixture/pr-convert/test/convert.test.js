'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { convert } = require('../src/convert');

test('convert uses the shared rate table to turn USD into EUR', () => {
  assert.strictEqual(convert(100, 'EUR'), 90);
});

test('convert rounds the result to two decimals', () => {
  assert.strictEqual(convert(1.11, 'GBP'), 0.89);
});

test('convert throws for an unknown currency code', () => {
  assert.throws(() => convert(1, 'XXX'), /unknown currency/);
});
