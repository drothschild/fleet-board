## Status
done

## Findings
- [Critical] subtract(2, 5) returns 3 instead of -3
- [Important] subtract has no test for a negative result
- [Important] clamp is exported but not implemented
- [Minor] calc.js mixes quote styles

## For the card
Added subtract(a, b) to src/calc.js.

## PR
#12

VERIFIED: `node --test test/calc.test.js` -> 2 passing tests
