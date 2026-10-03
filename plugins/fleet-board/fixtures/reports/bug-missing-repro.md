## Status
done

## Findings
- none

## For the card
Added subtract(a, b) to src/calc.js.

Bugs found:
- add drops a third argument :: expected: 6 :: observed: 3

## PR
#12

VERIFIED: `node --test test/calc.test.js` -> 3 passing tests
