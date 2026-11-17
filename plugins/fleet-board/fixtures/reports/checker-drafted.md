## Status
drafted

## Findings
- none

## For the card
Drafted from the follow-up.

## Why
The stamp is lost on a move.

## Proposed scope
Change `plugins/fleet-board/scripts/premise.sh`.

## Proposed acceptance
- stamp survives a move
- stamp is read back

## Repro
- `bash plugins/fleet-board/tests/test-premise.sh` :: failed :: 1 case failed

VERIFIED: `bash plugins/fleet-board/tests/test-premise.sh` -> 1 suite read
