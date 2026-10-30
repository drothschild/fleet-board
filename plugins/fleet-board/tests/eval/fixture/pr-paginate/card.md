## Why
List screens need to split items into pages.

## Acceptance
- pageCount rounds up when the last page is partly full
- paginate returns the items of a full page
- paginate returns a short last page with the items that remain
- paginate returns an empty array for a page beyond the last
