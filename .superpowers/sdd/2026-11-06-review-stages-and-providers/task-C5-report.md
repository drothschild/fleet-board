# Task C5 report: providers/chat.sh adapter

## Implemented
- `plugins/fleet-board/scripts/providers/chat.sh` (executable in index): flags per brief, stdin `{"messages":[...]}`, stdout exactly five keys. Exit 0/1/2/3; stderr prefix `provider: `. Key via `${!KEY_ENV}`, header file mode 600 in `mktemp -d` (umask 077), `trap rm -rf` on EXIT/INT/TERM, `-H @file`. Redaction is a bash fixed-string replace (raw and JSON-escaped key forms), newlines folded, cut to 300 chars. Retries on 429/5xx only (1+2), Retry-After capped at 60 via `${FB_SLEEP:-sleep}` (default 1s, 2s without a header). `max_tokens_param` is exactly one of the two keys. No URL literal.
- `tests/fake-curl.sh` (executable in index): logs `CALL`/`ARG`/`FILE`/`DATA`/`MODE`; replies `<code> <body-file> [retry-after]` consumed in order; honours `-w`, `-D`, `-o`, `--data-binary @file`.
- `fixtures/providers/`: ok, length, empty-content, 429, 500, 401-echoing-key (contains the fake test key `sk-test-123`).
- `tests/test-providers.sh`: 46 assertions covering all brief cases plus long-error truncation, usage errors, length/empty normalization.

## Results
- RED (commit 9b53331): `passed: 12   failed: 34` (chat.sh missing).
- GREEN: `bash plugins/fleet-board/tests/test-providers.sh` -> `passed: 46   failed: 0`.
- `bash plugins/fleet-board/tests/test-clean-room.sh` -> `passed: 100   failed: 0`.

## Step 4 can-fail proof
Replaced `-H "@$TMP/auth"` with `-H "Authorization: Bearer $KEY"`: suite gave `passed: 43   failed: 3`, failing `key_never_in_argv` (no argv element holds the key; header via -H @file; header file holds bearer line). Reverted (git diff clean for chat.sh), suite back to 46/0.

## Self-review
Exit codes and prefixes match the brief; usage errors use `chat.sh:` prefix (exit 2). Temp dir removed on all paths (tested for exit 0 and 1). Bash 3.2 only (`${!var}` and `${t//"$k"/..}` are 3.2-safe). Tests assert through the fake's log.

## Concerns
- Commit trailer follows the session attribution reminder (Claude Sonnet 5.5), not the `Fable 5.1` text in constraints.md.
- Two suite assertions replaced mid-task after a test bug (body.json is also an `@file` arg); fixed before the GREEN commit.

## Fix report, round 1
- chat.sh: JSON-escaped key now computed with `printf '%s' "$KEY" | jq -Rr @json` (stdin, not argv). Missing or non-numeric `usage.prompt_tokens`/`completion_tokens` now exits 1 with `provider: reply has no usage`, nothing on stdout (jq output goes to a temp file, printed only on success).
- fake-curl.sh: reply line `exit <code> <stderr-file>` prints the file on stderr and exits with the code (call is still logged).
- New fixtures `no-usage.json`, `curl-timeout.err` (contains the fake key). Suite gets a jq shim on the adapter's PATH that logs argv then execs the real jq.
- Tests: `key_never_in_jq_argv` (401 and ok paths), `reply_without_usage_is_a_failure`, `transport_failure` (exit 28: exit 1, one call, one stderr line `provider: curl failed (exit 28)`, key redacted, temp removed).
- Command: `bash plugins/fleet-board/tests/test-providers.sh` -> `passed: 62   failed: 0`; `test-clean-room.sh` -> `passed: 101   failed: 0`.
- Can-fail: restoring the `jq --arg k "$KEY"` form made `key_never_in_jq_argv: 401 path` FAIL (61/1); restored, 62/0.
