# Completion-driven manager behavioral scenario

Status: prepared; requires explicit paid-run approval. This is a behavioral acceptance protocol, not an offline test result.

## Fixture and isolation

Use a disposable local-board repository and a copied plugin. Load only that plugin with a fresh empty CLAUDE_CONFIG_DIR and assert the system/init plugin list. The generated manager is the subject; use scripted fixture role agents/providers for reports. Never point this scenario at the production board. Use fake gh for all PR reads/writes, real board adapters and note parsing, and stub verify-main.sh with controlled JSON.

Set limits.concurrency to 2, merge.policy to human, review.max_rounds to 2. Ready cards A and B have disjoint scopes and acceptance criteria. Card C overlaps A and must remain Ready until A stops reserving its scope. Provide controlled PR heads and strict valid reports with VERIFIED commands. Log task starts, task completions, note writes and board transitions as ordered JSONL events.

## Core test: fast card advances while another worker is running

1. A's implementor returns a valid PR report promptly.
2. B's implementor waits for an A-review-complete marker, with a bounded fallback timeout that records a failure marker before returning its report.
3. A's reviewer returns a clean current-head report and writes the marker. Capture the manager's accepted last_review note separately, so a provider-produced marker alone is not sufficient proof.
4. Assert A's implementor is reconciled and A's review starts and is reconciled before B completes. The old foreground batch manager should fail this ordering assertion.
5. Assert B is eventually reconciled; the final tick report arrives only after both task completions. Maximum simultaneous roles is two, and maximum roles on any one card is one.
6. Assert C was not dispatched while A was in progress or review. The wrapper owns merges, so no headless manager gh merge is expected in this scenario.

## Controlled failure variations

- Deliver a duplicate A completion notification: each report, note outcome, round update and follow-up is recorded once.
- Change A's PR head while its reviewer runs: persist the reviewed dispatch SHA; a fresh plan must request review of the new head before merge eligibility.
- Make a role report invalid twice: exactly one retry, then retire that card for the tick; another runnable card continues.
- Make the second planner call fail while B is running: no new workers start; reconcile already-dispatched final reports and emit Plan failed with actual accumulated cost.
- Return the same actionable plan repeatedly without state change: dispatch budget and per-card retirement stop a busy loop, with no outstanding worker at tick end.
- Place a card in Human QA during a worker run: no transition moves it out of Human QA, and no merge occurs.
- Return failed verification: no further merges or new worker admissions; preserve evidence and drain already-running results safely.

## Evidence and approval boundary

Before the isolated author run, review the manager spec diff and re-author request. After generation, check only intended hunks changed, update the clean-room manifest and audit record, then run the offline clean-room guard. Run the core behavioral scenario once under a separately approved budget; failures remain failures and require a reviewed follow-up rather than an unapproved paid retry. Record timestamps, task IDs, exact tested commit, isolation evidence, result assertions and actual spend.
