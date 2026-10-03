## Status
clean

## Findings
- none

## For the card
Reviewed the subtract PR.

## Acceptance map
- subtract(5, 2) returns 3
- subtract(2, 5) returns -3 -> test/calc.test.js::subtract(2, 5) returns -3

## Mutation
killed: 2 survived: 0 invalid: 1

## Claim check
claim: node --test test/calc.test.js passes 3 tests
command: `node --test test/calc.test.js`
result: tests 3, pass 3, fail 0
matches: yes

VERIFIED: `node --test test/calc.test.js` -> 3 passing tests
