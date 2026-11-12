## Status
not_reproducible

## Findings
- none

## For the card
Ran the failing case from the finding; subtract(2, 5) already returns -3 on this head.

## PR
#12

## Resolutions
- [Important] subtract(2, 5) returns -3 is unmapped :: not fixed: could not reproduce on the current head

VERIFIED: `node --test test/calc.test.js` -> 3 passing tests
