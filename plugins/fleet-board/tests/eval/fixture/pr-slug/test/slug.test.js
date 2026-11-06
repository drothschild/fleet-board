'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { slugify } = require('../src/slug');

test('slugify lowercases the text', () => {
  assert.strictEqual(slugify('Hello'), 'hello');
});

test('slugify replaces each run of non-alphanumerics with one hyphen', () => {
  assert.strictEqual(slugify('a  b!!c'), 'a-b-c');
});

test('slugify leaves no leading or trailing hyphen', () => {
  assert.strictEqual(slugify('  Hi there!  '), 'hi-there');
});

test('slugify truncates to max characters without a trailing hyphen', () => {
  assert.strictEqual(slugify('ab cd ef', 3), 'ab');
});
