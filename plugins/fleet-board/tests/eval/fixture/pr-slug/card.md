## Why
Page titles need URL-safe slugs.

## Acceptance
- slugify lowercases the text
- slugify replaces each run of non-alphanumerics with one hyphen
- slugify leaves no leading or trailing hyphen
- slugify truncates to max characters without a trailing hyphen
