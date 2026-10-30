## Why
Callers need to keep a number inside a range.

## Acceptance
- clamp returns n when it is within lo and hi
- clamp returns lo when n is below lo
- clamp returns hi when n is above hi
- clamp throws a RangeError when lo is greater than hi
