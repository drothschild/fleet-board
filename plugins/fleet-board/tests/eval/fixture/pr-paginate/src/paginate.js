'use strict';

function pageCount(total, size) {
  return Math.ceil(total / size);
}

function paginate(items, page, size) {
  return items.slice((page - 1) * size, page * size);
}

module.exports = { pageCount, paginate };
