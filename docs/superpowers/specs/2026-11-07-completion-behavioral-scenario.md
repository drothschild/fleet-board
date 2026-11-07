# Completion-driven manager behavioral scenario

Status: runtime validation pending. The approved attempt cost $0.1315963 and dispatched no reviews because bare mode omitted Write. Tool configuration is corrected; another paid attempt requires approval.

## Fixture and isolation

`tests/behavioral-completion.sh` creates a disposable local board and copied plugin with a fresh configuration directory. It runs the generated manager with scripted evidence-review providers, fake GitHub calls, real board adapters and real note parsing. No production board is used. Concurrency is two, merge policy is human, and three In Review cards have controlled PR heads and valid reports.

## Core test: fast review reconciles and refills a slot

1. Review A waits until review B has started, then returns its clean report.
2. Review B waits for both review C to start and A's accepted current-head review note plus Human QA transition. A bounded timeout fails the scenario.
3. C returns promptly. Assert A finishes before C starts and C starts before B finishes.
4. Assert the reconciliation checkpoint precedes B's completion, all three reviews finish, capacity never exceeds two, each card launches once, all final review notes preserve the dispatched SHA and round, and all cards reach Human QA.
5. Assert the generated manager returns successfully, the plugin isolation check passes, and no merge command was issued.

The offline preparation also checks that the event assertion rejects a batch-order trace. This core run exercises evidence-provider completion and slot refill. It does not establish Agent-role scheduling, implementation-to-review chaining, overlapping-scope admission, or the variations below; scope admission has separate deterministic tests.

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
