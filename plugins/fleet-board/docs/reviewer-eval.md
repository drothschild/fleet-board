# Reviewer eval: seeded-defect catch rate

The reviewer is the part of fleet-board that justifies the rest, and one anecdote is not a measurement. This eval turns "the reviewer catches things" into a catch rate: seed a known defect into a small correct PR whose tests still pass, ask the reviewer to review it, and count how often its report names the defect at **Critical** or **Important**.

**Status: harness built, full run not yet done.** The results table below is a template. Nothing in it is a measurement until the Human QA step (the paid run) fills it in.

## What is in `tests/eval/`

| Path | What it is |
|---|---|
| `fixture/pr-clamp`, `pr-paginate`, `pr-slug`, `pr-convert` | Four small correct PRs. Each has `card.md` (with an `## Acceptance` section), `src/`, `test/` and `test.sh`, whose suite passes unmodified. |
| `defects/catalogue.tsv` | One row per seeded defect: id, class, fixture PR, patch file, and the pattern a finding must match to count as naming the defect. |
| `defects/*.patch` | The six defects, one patch each. Each applies cleanly to its fixture PR and leaves that PR's suite passing. |
| `run.sh` | The runner. |
| `parse-result.sh` | The result parser: `caught` only if a Critical or Important finding matches the defect's pattern. |
| `canned/` | One caught and one missed canned reviewer report, used by the parser test. |

Defect classes: off-by-one with a test that still passes (`off-by-one`), a test asserting on source text instead of behavior (`source-text-assertion`), a weakened assertion (`weakened-assertion`), an Acceptance bullet with no test (`untested-bullet`), a mocked dependency that hides the bug (`mocked-dependency`), and a happy-path-only test (`happy-path-only`).

## Offline checks (free)

```bash
bash plugins/fleet-board/tests/test-eval-fixtures.sh   # fixtures pass, patches apply, suites still pass with each defect
bash plugins/fleet-board/tests/test-eval-run.sh        # dry run, flags, result parser
bash plugins/fleet-board/tests/eval/run.sh --dry-run   # prints every claude -p --bare command, runs nothing
```

## Running the eval (paid)

Each run is one `claude -p --bare` reviewer session with a fresh `CLAUDE_CONFIG_DIR`, so no installed plugin, hook or personal instruction is loaded. Auth comes from the settings file in `FB_ISOLATE_SETTINGS` (default `~/.config/fleet-board/bare-settings.json`, an `apiKeyHelper` file), as in the other behavioral suites.

```bash
cd plugins/fleet-board/tests/eval
bash run.sh --runs 3 --mutation on  --model opus     # 6 defects x 3 runs
bash run.sh --runs 3 --mutation off --model opus
bash run.sh --runs 3 --mutation on  --model sonnet   # repeat for each candidate model
bash run.sh --defect off-by-one --runs 1             # one defect, one run
```

Flags: `--runs N` (default 3), `--mutation on|off`, `--model <name>`, `--defect <id>`, `--out <dir>`, `--dry-run`. An unknown flag exits 2. The runner prints a catch-rate table per class and keeps each run's report, transcript and cost in `--out`, with one row per run in `results.tsv` (id, class, run, model, mutation, verdict, cost in USD).

The runner gives the reviewer the card body, the PR diff and a made-up implementor report; there is no GitHub PR, so the reviewer is told not to call `gh` or `board-comment.sh`.

## Results

Catch rate is caught runs over total runs. A run counts as caught only when the report names the defect at Critical or Important; naming it as Minor, or only in prose, is a miss.

| Class | Model | review.mutation | Caught | Runs | Catch rate | Cost (USD) |
|---|---|---|---|---|---|---|
| off-by-one | opus | on | not run | | | |
| off-by-one | opus | off | not run | | | |
| source-text-assertion | opus | on | not run | | | |
| source-text-assertion | opus | off | not run | | | |
| weakened-assertion | opus | on | not run | | | |
| weakened-assertion | opus | off | not run | | | |
| untested-bullet | opus | on | not run | | | |
| untested-bullet | opus | off | not run | | | |
| mocked-dependency | opus | on | not run | | | |
| mocked-dependency | opus | off | not run | | | |
| happy-path-only | opus | on | not run | | | |
| happy-path-only | opus | off | not run | | | |

Add the same rows for each candidate model (for example sonnet).

### Cost per run

One line per eval invocation, copied from the runner's table and its `results.tsv`:

```
<date>  bash run.sh --runs 3 --mutation on --model opus   18 runs  total $<sum of the cost column>  mean $<per run>
```

No invocations recorded yet.
