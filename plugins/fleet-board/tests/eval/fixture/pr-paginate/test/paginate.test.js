'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { pageCount, paginate } = require('../src/paginate');

test('pageCount rounds up when the last page is partly full', () => {
  assert.strictEqual(pageCount(11, 5), 3);
  assert.strictEqual(pageCount(7, 3), 3);
});

test('paginate returns the items of a full page', () => {
  assert.deepStrictEqual(paginate([1, 2, 3, 4, 5, 6], 2, 3), [4, 5, 6]);
});

test('paginate returns a short last page with the items that remain', () => {
  assert.deepStrictEqual(paginate([1, 2, 3, 4, 5], 2, 3), [4, 5]);
});

test('paginate returns an empty array for a page beyond the last', () => {
  assert.deepStrictEqual(paginate([1, 2, 3], 5, 3), []);
});
