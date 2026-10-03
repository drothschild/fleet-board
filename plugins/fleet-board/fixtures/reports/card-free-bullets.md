## Status
done

## Findings
- none

## For the card
Added subtract(a, b) to src/calc.js.
Changes:
- src/calc.js exports subtract
- test/subtract.test.js covers both Acceptance bullets

Out of scope:
- Add multiply :: calc has no multiply

Notes after the list:
- a plain bullet under a text line is free text

## PR
#12

VERIFIED: `node --test test/calc.test.js` -> 3 passing tests
