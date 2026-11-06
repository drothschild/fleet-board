# Reviewer eval: seeded-defect catch rate

The reviewer is the part of fleet-board that justifies the rest, and one anecdote is not a measurement. This eval turns "the reviewer catches things" into a catch rate: seed a known defect into a small correct PR whose tests still pass, ask the reviewer to review it, and count how often its report names the defect at **Critical** or **Important**.

**Status: measured for opus, with `review.mutation` on and off.** In both settings the reviewer caught 6 of 6 defect classes in 3 of 3 runs each. Rows marked `not run` have not been measured.

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
bash plugins/fleet-board/tests/eval/run.sh --dry-run   # prints every claude -p command, runs nothing
```

## Running the eval (paid)

Each run is one `claude -p` session with a fresh `CLAUDE_CONFIG_DIR`, so no installed plugin, hook or personal instruction is loaded. It is not `--bare`, because `--bare` removes the Agent tool and the session has to dispatch the reviewer. Auth comes from the settings file in `FB_ISOLATE_SETTINGS` (default `~/.config/fleet-board/bare-settings.json`, an `apiKeyHelper` file), as in the other behavioral suites.

```bash
cd plugins/fleet-board/tests/eval
bash run.sh --runs 3 --mutation on  --model opus     # 6 defects x 3 runs
bash run.sh --runs 3 --mutation off --model opus
bash run.sh --runs 3 --mutation on  --model sonnet   # repeat for each candidate model
bash run.sh --defect off-by-one --runs 1             # one defect, one run
```

To measure a provider-backed stage reviewer instead of the Claude reviewer, use `run.sh --provider`:

```bash
bash run.sh --provider openai --model <id> --price-in <P> --price-out <P> --runs 3
```

With `OPENAI_API_KEY` exported in your shell, each run calls `scripts/stage-review.sh` (no `claude -p`) with a temporary `.fleet-board.yml` holding one blocking stage on that provider and model, so it needs the price in USD per million tokens. It sends each fixture's card and diff to the provider, and it costs that provider's money. `results.tsv` records the model as `<provider>:<id>`; the ledger and each report land under `--out`.

Flags: `--runs N` (default 3), `--mutation on|off`, `--model <name>`, `--defect <id>`, `--out <dir>`, `--dry-run`. An unknown flag exits 2. The runner prints a catch-rate table per class and keeps each run's report, transcript and cost in `--out`, with one row per run in `results.tsv` (id, class, run, model, mutation, verdict, cost in USD). The verdict is `caught`, `missed` or `error`. A run is an `error` when its transcript shows no dispatch of the reviewer or its report has no `## Findings` section; errored runs are left out of the catch rate and make the runner exit 1.

The runner gives the reviewer the card body, the PR diff and a made-up implementor report; there is no GitHub PR, so the reviewer is told not to call `gh` or `board-comment.sh`.

## Results

Catch rate is caught runs over total runs. A run counts as caught only when the report names the defect at Critical or Important; naming it as Minor, or only in prose, is a miss.

| Class | Model | review.mutation | Caught | Runs | Catch rate | Cost (USD) |
|---|---|---|---|---|---|---|
| off-by-one | opus | on | 3 | 3 | 100% | 0.76 |
| off-by-one | opus | off | 3 | 3 | 100% | 0.55 |
| source-text-assertion | opus | on | 3 | 3 | 100% | 0.61 |
| source-text-assertion | opus | off | 3 | 3 | 100% | 0.48 |
| weakened-assertion | opus | on | 3 | 3 | 100% | 0.62 |
| weakened-assertion | opus | off | 3 | 3 | 100% | 0.52 |
| untested-bullet | opus | on | 3 | 3 | 100% | 0.54 |
| untested-bullet | opus | off | 3 | 3 | 100% | 0.47 |
| mocked-dependency | opus | on | 3 | 3 | 100% | 0.65 |
| mocked-dependency | opus | off | 3 | 3 | 100% | 0.55 |
| happy-path-only | opus | on | 3 | 3 | 100% | 0.59 |
| happy-path-only | opus | off | 3 | 3 | 100% | 0.46 |
| off-by-one | openai:<id> | n/a | not run | not run | not run | not run |
| source-text-assertion | openai:<id> | n/a | not run | not run | not run | not run |
| weakened-assertion | openai:<id> | n/a | not run | not run | not run | not run |
| untested-bullet | openai:<id> | n/a | not run | not run | not run | not run |
| mocked-dependency | openai:<id> | n/a | not run | not run | not run | not run |
| happy-path-only | openai:<id> | n/a | not run | not run | not run | not run |

Add the same rows for each candidate model (for example sonnet). The `openai:<id>` rows are for a provider-backed review stage (the stage reviewer, which sees the card and the diff but runs no tests and no mutation, so `review.mutation` does not apply); they read `not run` until someone runs `run.sh --provider` with a real key.

Every report was also scored by hand against the defect's patch, and the hand score agreed with the automated score on all 18 runs: each report named the seeded defect at Critical or Important. In one run (`weakened-assertion` run 2) the weak assertion itself was only Minor, but the wrong return value it hides and the surviving mutant were both Critical, so it counts as caught.

With `review.mutation` off, the catch rate was the same 100% in every class, so on these fixtures the mutation check did not change whether the reviewer caught the defect. It did change the cost: the off runs were cheaper (about $3.03 for 18 runs, against about $3.8 with mutation on).

What this does not show:

- **Whether the mutation check matters.** At a 100% catch rate in both settings there is no difference to measure. The seeded defects are probably too easy to separate the two; a harder catalogue is needed to show what the mutation check adds.
- **Small sample and small PRs.** Three runs per class, on four fixture PRs of a few lines each, where the defect is a large part of the diff. Expect a lower rate on real PRs.
- **No false-positive measure.** Every fixture PR has a defect, so this says nothing about how often the reviewer flags a correct PR.
- **Patterns not stress-tested.** The catalogue patterns are loose, but every matching finding here was genuine, so this run could not expose a false match.

### Cost per run

One line per eval invocation, copied from the runner's table and its `results.tsv`:

```
2026-11-01  bash run.sh --runs 3 --mutation on --model opus   18 runs  total $3.76  mean $0.21
2026-11-06  bash run.sh --runs 3 --mutation on --model opus   18 runs  total $3.81  mean $0.21
2026-11-06  bash run.sh --runs 3 --mutation off --model opus  18 runs  total $3.03  mean $0.17
```

The cost includes the reviewer subagent's usage. Two other paid invocations are not part of the results: an earlier run of 18 under `--bare`, where the reviewer was never dispatched ($0.41), and a one-run cost probe of `off-by-one` ($0.39).
