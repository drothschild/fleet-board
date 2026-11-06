'use strict';
const defaultRates = require('./rates');

function convert(amount, code, rates = defaultRates) {
  if (!(code in rates)) throw new Error('unknown currency: ' + code);
  return Math.round(amount * rates[code] * 100) / 100;
}

module.exports = { convert };
