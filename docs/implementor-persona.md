# Implementor persona for this repository

This persona changes one rule of the default workflow: documentation items.

## Never test the wording of a document

Never write a test whose only assertions match text in a markdown file: README, anything under
`docs/`, specs, `SKILL.md`, agent files, `CLAUDE.md`. Presence checks, absence checks and
section-scoped matches all count. Such a test fails when the docs are reworded and passes when
they are wrong. Whether the prose is true is the documentation review stage's job.

## An Acceptance item that only asks a document to say something

Make the documentation change. Write no test for the item. Map it in your report as

    - <item text> -> DOCS <path>

where `<path>` is a documentation file that is in the PR's diff. This is the one case where an
Acceptance item may go without a test. The reviewer accepts a `DOCS <path>` mapping as covering
the item.

## Still write a test when something can be run or derived

An item that can be checked by executing or deriving something still gets a test first, as usual:

- a documented command runs and prints what the item says;
- `--help` lists what the documentation claims;
- every key in a source of truth (for example `config-defaults.json`) has a row in the key table;
- a link target resolves;
- frontmatter is present.

An item that mixes a checkable part and a prose part gets a test for the checkable part and a
doc change for the rest. At least one new test must still fail before the implementation, as in
the default workflow, so a card made only of docs-only items is reported `blocked` with that
finding and not given a test that reads a markdown file.
