# fleet-board

[![tests](https://github.com/drothschild/fleet-board/actions/workflows/tests.yml/badge.svg)](https://github.com/drothschild/fleet-board/actions/workflows/tests.yml)

A Claude Code plugin that turns a GitHub issue board into a work queue for a fleet of coding agents, with hook-enforced human-QA and merge gates.

## Install

Tell Claude Code:

> Go to https://github.com/drothschild/fleet-board and follow the install directions.

Claude does the rest. The one step it cannot do for you is logging in to GitHub, if you have never run `gh auth login`.

To install by hand instead, run these in Claude Code and start a new session:

```
/plugin marketplace add drothschild/fleet-board
/plugin install fleet-board@fleet-board
```

### Install directions for Claude

Follow these steps in order, running each command with your shell tool. fleet-board needs only `git`, `jq` and `gh`; do not install anything else.

1. **Check the tools.** Run `git --version`, `jq --version` and `gh --version`. `git` and `jq` ship with macOS 15 and later. For each one missing:
   - with Homebrew (`command -v brew` succeeds), run `brew install <tool>` yourself;
   - otherwise give the user the install command for their system (for example `sudo apt-get install -y <tool>`), since it needs their password, and wait for them.
2. **Install the plugin:**

   ```bash
   claude plugin marketplace add drothschild/fleet-board
   claude plugin install fleet-board@fleet-board
   ```

   If the marketplace is already added, run `claude plugin marketplace update fleet-board` and continue.
3. **Check the GitHub login.** Run `gh auth status`. If it reports no login, ask the user to run `gh auth login` in a terminal and choose the browser login; it is interactive, so do not run it yourself. Scopes are checked later by `/fleet-board:init`.
4. **Finish.** Tell the user that fleet-board is installed, that it loads in a **new** Claude Code session, and that the next step is to open that session in the repository they want to manage and run `/fleet-board:init`. Point them to the [plugin README](plugins/fleet-board/README.md) for a first-hour walkthrough.

Everything else is in the [plugin README](plugins/fleet-board/README.md): requirements, a first-hour walkthrough on a fresh repo, [adding fleet-board to an existing project](plugins/fleet-board/README.md#adding-fleet-board-to-an-existing-project), the config reference and the gates.

MIT licensed.

## Design

The decisions behind the board, the gate and the review process, with the alternatives considered, are in [docs/design.md](docs/design.md).
