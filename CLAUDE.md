# fleet-board — Claude Instructions

Claude Code plugin marketplace for fleet-board. Plugins are the unit of distribution; each plugin
bundles one or more Claude primitives.

## Structure

```
.claude-plugin/marketplace.json    # top-level plugin registry
plugins/<plugin-name>/             # one directory per plugin
  .claude-plugin/plugin.json       # plugin manifest — the ONLY location the loader reads
  skills/<skill-name>/SKILL.md     # one directory per skill
docs/                              # repo-level documentation
```

## Plugin Conventions

- Directory name is the plugin's canonical name (kebab-case).
- Each plugin has **exactly one** manifest, at `.claude-plugin/plugin.json`, with `name`,
  `version` (semver), `description`, `author`, `license`. **Never add a `plugin.json` at the
  plugin root** — the loader does not read it, so it cannot fail loudly; it just drifts out
  of sync until the two disagree.
- Skills are directories: `skills/<skill-name>/SKILL.md`, with supporting material in
  `skills/<skill-name>/references/`. A flat `skills/<skill-name>.md` is **not discovered**
  and the skill will never be selected.
- Every `SKILL.md` opens with YAML frontmatter containing `name` and `description`. The
  `description` is the only thing Claude matches on when deciding whether to use the skill —
  state the trigger condition, not just the capability. A skill without frontmatter is
  unselectable.
- `user-invocable: true` makes a skill reachable as `/<plugin-name>:<skill-name>`. Omit it or
  set `false` for skills only the model should invoke.
- Agents are flat files: `agents/<agent-name>.md`, with frontmatter `name`, `description`,
  `model`, and optionally `tools` (an array) and `color`.
- Reference material a skill consults is **not** a skill. Put it in that skill's
  `references/` directory so it is not competing for selection.
- Subdirectories only exist if that primitive type is present: `skills/`, `commands/`,
  `rules/`, `hooks/`, `agents/`, `mcp-servers/`; `scripts/` for supporting executables.
- Each plugin has its own `README.md`.

## Adding a New Plugin

1. Create `plugins/<plugin-name>/`
2. Add `.claude-plugin/plugin.json` with full metadata — **not** a root-level `plugin.json`
3. Add primitive files in the appropriate subdirectory
4. Register the plugin in `.claude-plugin/marketplace.json`
5. Bump the plugin's version in both `.claude-plugin/plugin.json` and `marketplace.json`
   when making changes

## Git

- Never commit directly on `main` — branch first.
- `git add`, `git commit`, and `git push` are pre-approved.
- Never `git push --force`.

## Versioning

Plugins version independently using semver. `marketplace.json` tracks each plugin's current
version; the two must not drift.

## Primitive Types

| Type | Directory | Purpose |
|------|-----------|---------|
| Skills | `skills/<name>/SKILL.md` | Reusable instructions Claude follows on demand |
| Commands | `commands/` | Slash commands for Claude Code |
| Rules | `rules/` | Always-on behavioral rules |
| Hooks | `hooks/` | Shell commands triggered by Claude Code events |
| Agents | `agents/<name>.md` | Specialized subagent definitions |
| MCP Servers | `mcp-servers/` | Model Context Protocol servers |

## Portability

Plugins must run on a machine that is not mine.

- Never reference an absolute path or a personal directory. Use `${CLAUDE_PLUGIN_ROOT}` for
  anything shipped inside the plugin — scripts, references, assets. It is set for hooks,
  commands, and skills alike.
- Do not hardcode an install location. Plugins install under
  `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`, a path no plugin should write
  down.
- Do not depend on another plugin, or on a repo outside this marketplace.
- User data written at runtime belongs under `$HOME`, with an environment variable to
  override the location.

## Performance

Anything on a hot path — status lines, `SessionStart` hooks, `UserPromptSubmit` hooks — pays
its cost on every render or every message. Prefer one subprocess doing all the work to
several doing one field each.

## Testing

- Shell scripts shipped in a plugin are verified by plain-bash assertion suites under
  `plugins/<name>/tests/`. No external framework — `bats`, `shellcheck`, and `shunit2` are
  not assumed to be installed.
- Markdown primitives (skills, agents) are instructions, not code. Verify them
  **behaviorally**: give a subagent the skill plus a fixture and assert on the artifacts it
  produces. Do not claim a markdown file has unit tests.
- A test suite that has never failed proves nothing. Prove each suite can fail before
  trusting it.
- To run or author a primitive free of the local setup, use `claude -p --bare` with a
  fresh empty `CLAUDE_CONFIG_DIR`. Plain `--bare` still loads installed user plugins.
  Assert on the session's `system/init` event that no user plugin loaded.

## Shell Portability

Plugin scripts must run under macOS `/bin/bash` 3.2 and with both BSD and GNU tools:

- no bash 4 features;
- `sed -i.bak`, never bare `sed -i` or `sed -i ""`;
- `unset CDPATH` before any `cd` whose output is captured;
- `LC_ALL=C` for any `awk` that reads or prints a decimal.

## Plugin Context Files

A plugin with non-trivial contracts keeps its own `plugins/<name>/CLAUDE.md`
(currently `fleet-board`). Read it before changing that plugin.

Last verified: 2026-09-29
