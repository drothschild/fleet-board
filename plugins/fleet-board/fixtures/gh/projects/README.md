# GitHub Projects Fixtures

Real Projects v2 output captured from HMB board (project 1, owner drothschild) on 2026-09-28.

## Capture Commands

```bash
D=plugins/fleet-board/fixtures/gh/projects
gh project view 1 --owner drothschild --format json > $D/project-view.json
gh project field-list 1 --owner drothschild --format json > $D/field-list.json
gh project item-list 1 --owner drothschild --format json --limit 6 > $D/item-list.json
gh auth status > $D/auth-status-ok.txt 2>&1
N="$(jq -r '[.items[] | select(.content.type=="Issue")][0].content.number' $D/item-list.json)"
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){projectItems(first:20){nodes{id project{number} fieldValueByName(name:"Status"){... on ProjectV2ItemFieldSingleSelectValue{name}}}}}}}' \
  -f o=drothschild -f r=HMBWorkout -F n="$N" > $D/issue-project-items.json
```

## jq Paths

The following paths locate fields in the fixtures:

### item-list.json

- **Status value:** `.status` (string, e.g., "Ready", "Won't Do", "Require Human Inteteraction")
- **Content number:** `.content.number` (integer)
- **Content type:** `.content.type` (string, "Issue" or "PullRequest")
- **Repository:** `.repository` (string in form "owner/name" within content, or full URL in top-level)
  - In content: `.content.repository`
  - At item level: `.repository` (full URL)

Example: `.items[] | select(.content.type=="Issue") | .status`

### field-list.json

- **Status field options:** `.fields[] | select(.name=="Status") | .options[]`

The Status options have the shape:
```json
{
  "id": "option_id_string",
  "name": "Option Name"
}
```

Options found on HMB board:
- Backlog (id: f75ad846)
- Ready (id: 61e4505c)
- Require Human Inteteraction (id: 2a52dd0b)
- In progress (id: 47fc9ee4)
- In review (id: df73e18b)
- Done (id: 98236657)
- Won't Do (id: a44ddb87)
- Blocked (id: 7346e124)

**Blocked, and the two field-list fixtures.** The plan assumed HMB's board has no `Blocked` option, but the live board had one on 2026-09-28. The tests need both situations, so:

- `field-list-with-blocked.json` is the real capture, with all 8 options.
- `field-list.json` is derived from it with the `Blocked` option removed. The `unknown-option` and `projects-missing-option` cases rely on that absence. Derivation:
  `jq '(.fields[] | select(.name=="Status") | .options) |= map(select(.name != "Blocked"))' field-list-with-blocked.json`

### issue-project-items.json (GraphQL)

- **GraphQL Status path:** `.data.repository.issue.projectItems.nodes[0].fieldValueByName.name`

### Derived GraphQL fixture

- `issue-project-items-multi.json`: the issue is on two projects. A project-2 item (status
  `Done`) comes first; the project-1 item (`PVTI_lAHOACFUls4BfgODzg6jCC4`, status
  `In review`) second. Derived by hand from `issue-project-items-ready.json`.

### Derived `gh auth status` fixtures

Hand-written from the shape of `auth-status-ok.txt`; none is a live capture.

- `auth-status-not-logged-in.txt`: what `gh auth status` prints, with exit 1, when no
  account is logged in. It has no `Token scopes:` line.
- `auth-status-multi-active-first.txt`: two accounts. The active one (listed first, as gh
  lists it) lacks `'project'`; the inactive one has it.
- `auth-status-multi-inactive-first.txt`: the same two accounts with the inactive one listed
  first, so a check that reads the first `Token scopes:` line picks the wrong account.
- `auth-status-multi-active-ok.txt`: the active account has `'project'`; the inactive one
  lacks it (and `'repo'`).
- `auth-status-multi-host.txt`: two hosts, each with an active account. `ghe.example.com`
  is listed first and has `'project'`; `github.com` lacks it. The adapters talk to
  github.com, so only its block counts.
- `auth-status-multi-host-ok.txt`: the same two hosts with the scopes swapped:
  `ghe.example.com` lacks `'project'` and `'repo'`, and `github.com` has both.
- `auth-status-legacy-unquoted.txt`: the shape older gh versions print, from before
  multi-account support: no `Active account:` line, and the scopes unquoted
  (`Token scopes: gist, project, ...`). The suites derive the lacking-scope variants from
  it with `sed`.

## Sanitization

- Issue titles replaced with "Card <number>"
- Issue bodies replaced with "(fixture)"
- Auth token fragment replaced with "gho_REDACTED"
- Auth account login replaced with "REDACTED"
- Node IDs preserved (not secrets)
- Token scopes line preserved verbatim
