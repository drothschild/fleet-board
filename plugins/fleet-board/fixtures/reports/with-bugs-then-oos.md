## Status
done

## Findings
- none

## For the card
Added subtract(a, b) to src/calc.js.
Bugs found:
- add drops a third argument :: repro: `node -e "console.log(require('./src/calc.js').add(1, 2, 3))"` :: expected: 6 :: observed: 3
Out of scope:
- Add multiply :: calc has no multiply; a later card could add it

## PR
#12

VERIFIED: `node --test test/calc.test.js` -> 3 passing tests
