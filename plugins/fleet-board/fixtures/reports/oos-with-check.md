## Status
done

## Findings
- none

## For the card
Added subtract(a, b) to src/calc.js.

Out of scope:
- Add multiply :: calc has no multiply; `node -e "console.log(typeof require('./src/calc.js').multiply)"` should print function

## PR
#12

VERIFIED: `node --test test/calc.test.js` -> 3 passing tests
