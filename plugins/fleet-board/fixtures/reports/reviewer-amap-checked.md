## Status
clean

## Findings
- none

## For the card
Two Acceptance items have no test to map to.

## Acceptance map
- subtract(5, 2) returns 3 -> test/calc.test.js::subtract(5, 2) returns 3
- npm run typecheck exits 0 -> CHECKED: `npm run typecheck`
- If the fix needs a schema change, it comes with a migration -> NOT_APPLICABLE: the diff changes no schema file

## Mutation
killed: 1 survived: 0 invalid: 0

## Claim check
skipped: review.verify_claim is off

VERIFIED: `node --test test/calc.test.js` -> 1 passing test
