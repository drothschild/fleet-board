## Status
findings

## Findings
- [Important] subtract(2, 5) returns -3 has no test

## For the card
One Acceptance bullet has no test.

## Acceptance map
- subtract(5, 2) returns 3 -> test/calc.test.js::subtract(5, 2) returns 3
- subtract(2, 5) returns -3 -> UNMAPPED

## Mutation
skipped: review.mutation is off

## Claim check
skipped: review.verify_claim is off

VERIFIED: `node --test test/calc.test.js` -> 2 passing tests
