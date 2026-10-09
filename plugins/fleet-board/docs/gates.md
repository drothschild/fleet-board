# Gates and other plugins

## The gates

`hooks/gate.sh` is a `PreToolUse` hook on Bash. It reads every Bash command the manager or a role agent is about to run, and blocks it with exit 2 and a one-line reason:

1. **Human QA.** Nothing moves a card out of `human_qa`: not `board-move.sh`, `gh issue edit`, `gh project item-edit`/`item-archive`/`item-delete`, editing or deleting a state label, or a raw label or Status API write.
2. **Merges.** Under `merge.policy: human`, every `gh pr merge` is blocked. Under `auto`, a merge is blocked when it uses `--admin`, names no PR, targets a draft, or the PR's checks are not green. Raw merges through the API are blocked.
3. **Ready.** `board-move.sh N ready` is blocked when the card has no `## Acceptance` section.

The gate is inert in a directory without `.fleet-board.yml`, so it does nothing in other repos. With an invalid config, it fails closed and blocks board and merge commands until the file is fixed. A command with no gated keyword passes after one `jq` call, without reading the config or the network. When it can't tell what a gated command would do (a variable where a card, PR, state or directory belongs) or can't look up the board or PR in time, it blocks.

`FLEET_BOARD_GATE_TIMEOUT` caps the lookups in one call, in seconds: 45 by default, at most 50. The hook's own timeout is 60 seconds, after which Claude Code lets the call through. Without `jq`, the hook exits 0 silently, but every fleet-board script needs `jq` too, so board commands fail anyway.

## Limits

The gate reads command text before it runs. A string check cannot see:

- commands written to a script file and then run (`bash x.sh`);
- `gh api graphql -F query=@file`, and `-f query="$(cat q.graphql)"`;
- gh aliases (`gh alias set`) and gh extensions;
- HTTP clients other than `curl` and `gh api`: `wget`, `httpie`, `python -c`, `node -e` and so on;
- `gh issue close N` on a Projects board, whose auto-Done workflow moves the card (on the labels board, closing leaves the labels alone);
- `gh issue edit N --remove-project`, which takes the card off the board;
- `git push origin :main` and other pushes: merges by push are not gated;
- obfuscation beyond what the hook decodes: `$'gh'`, `eval "$(printf ...)"`, a variable holding a whole command (`C="gh pr merge 5"; $C`), `alias` with `shopt -s expand_aliases`, `env -C dir` or `sudo -D dir`, and shell functions defined in an earlier Bash call;
- `gh ... -R owner/board` or `GH_REPO=owner/board` from a directory without a config, which is inert by design;
- `parallel board-move.sh ::: 14 ::: done`;
- `cd -P link/..`, which the hook resolves logically and the shell physically.

It also blocks some harmless commands, because it prefers a block to a miss:

- commands that only mention a gated command, such as `git commit -m "fix gh pr merge docs"` or `grep -rn "gh pr merge" docs/` (quoted text is checked too, since `bash -c "..."` runs it);
- here-documents and comments containing a gated command;
- `cd <dir>; gh pr merge N` after `true &&`, in a pipeline, or after `||`;
- `cd "$VAR" && ...`, `source env.sh && ...` and `popd && ...` before a gated command, since the directory is unknown;
- calls over 64 KiB with a gated keyword, more than 32 gated commands in one call, or nesting deeper than 24.

To get past a false positive, put the text in a file (`git commit -F msg.txt`), phrase it differently, `cd` to a literal path, or split the call.

The gates stop agents that use the documented commands. Branch protection on GitHub remains the backstop for merges.

## Other plugins

Ticks and role agents load the other installed plugins and the user's `~/.claude/CLAUDE.md`, like any Claude Code session. A global instruction such as "open the PR in the browser" or a plugin hook that injects a skill mandate could, in principle, pull a role off its spec.

This was measured before release, on a setup with 16 other plugins (several with `SessionStart` and `UserPromptSubmit` hooks) and a global `CLAUDE.md` with branch, PR, TDD and browser directives. Across every role and tick transcript, no role invoked a foreign skill or agent, asked the user a question, opened a browser, or created a PR beyond the implementor's one required draft PR. Isolated runs of the implementor and reviewer, with no user plugins or `CLAUDE.md`, gave the same counts and results. So fleet-board ships no isolation (`ROLE_ISOLATION: none`). `FLEET_BOARD_ISOLATE` is unset by default, `0` means the same, and the headless wrapper refuses `1` with exit 2.

**Interactive use.** `/fleet-board:tick`, `/fleet-board:run`, or plain English such as "process the board" run inside the current interactive session, where no isolation could apply anyway. The same measurement covers this case, and found nothing (`INTERACTIVE_RISK: none`). For long runs, use the headless wrapper anyway: `/fleet-board:run` keeps the session busy and spends its context on every tick.

Other setups weren't measured. A plugin with its own `PreToolUse` hook can still block a role's commands; a rule-based hook plugin with rules that match `gh` or `git`, for example. If a tick report shows commands denied by something other than `fleet-board gate:`, look there first.

Names and gates can't conflict otherwise: plugin skills and agents are namespaced (`fleet-board:tick`, `fleet-board:implementor`), and the gate is the only `PreToolUse` hook fleet-board adds.
