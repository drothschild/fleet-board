## Status
done

## Findings
- none

## For the card
Added subtract(a, b) to src/calc.js.

Out of scope:
- Add multiply :: calc has no multiply; `grep -c multiply src/calc.js` should print 1
- Document calc :: the README does not list the exported functions; `grep -c add README.md` should print 1

## PR
#12

VERIFIED: `node --test test/calc.test.js` -> 3 passing tests
