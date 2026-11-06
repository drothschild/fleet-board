## Status
findings

## Findings
- [Important] pageCount is off by one: Math.floor(total / size) + 1 returns 3 for 10 items in pages of 5, and the tests only use totals that are not a multiple of the page size.
- [Minor] The card has no Why detail.

## For the card
One mutant survived in pageCount.

## Acceptance map
- pageCount rounds up when the last page is partly full -> test/paginate.test.js::pageCount rounds up when the last page is partly full

## Mutation
killed: 3 survived: 1 invalid: 0

## Claim check
skipped: review.verify_claim is off

VERIFIED: `node test/paginate.test.js` -> 4 passing tests
