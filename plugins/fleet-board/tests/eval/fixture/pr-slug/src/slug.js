'use strict';

function slugify(s, max) {
  let out = s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
  if (max !== undefined && out.length > max) {
    out = out.slice(0, max).replace(/-+$/, '');
  }
  return out;
}

module.exports = { slugify };
