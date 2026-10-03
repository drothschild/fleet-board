# Add clamp

Add a `clamp(value, min, max)` function to `src/calc.js` and export it next to `add`.

## Acceptance
- clamp(5, 0, 10) returns 5 (a value within range is unchanged)
- clamp(-3, 0, 10) returns 0 (a value below min returns min)
- clamp(42, 0, 10) returns 10 (a value above max returns max)
