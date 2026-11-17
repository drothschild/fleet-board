## Status
stale

## Findings
- none

## For the card
The script moved.

## What changed
plugins/fleet-board/scripts/premise.sh now owns the stamp.

## Proposed scope
Change `plugins/fleet-board/scripts/premise.sh` only.

## Proposed acceptance
- stamp writes the head
- stamp refuses a missing card

VERIFIED: `bash plugins/fleet-board/tests/test-premise.sh` -> 1 suite read
