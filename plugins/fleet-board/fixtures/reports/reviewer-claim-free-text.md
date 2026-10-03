## Status
clean

## Findings
- none

## For the card
Reviewed the subtract PR.

## Acceptance map
- subtract(5, 2) returns 3 -> test/calc.test.js::subtract(5, 2) returns 3
- subtract(2, 5) returns -3 -> test/calc.test.js::subtract(2, 5) returns -3

## Mutation
killed: 2 survived: 0 invalid: 1

## Claim check
I re-ran node --test test/calc.test.js and it passed.

VERIFIED: `node --test test/calc.test.js` -> 3 passing tests
