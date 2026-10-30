# Why fleet-board is built this way

- **The board is the state.** Cards on a GitHub issue board are the work queue, so a human can see and steer everything with tools they already use. Each card carries a machine-readable note recording its branch, worktree, PR and round.
- **Test first, then implement.** The implementor must commit failing tests on their own before any implementation, so the Acceptance bullets become checks that were seen to fail.
- **A separate, adversarial reviewer.** The reviewer is a different agent on a different model. It maps each Acceptance bullet to a test, mutates the code to see whether the tests notice, and re-runs the implementor's claims.
- **Gates are hooks, not requests.** Human-QA and merge gates are enforced by hooks, so a prompt cannot talk an agent past them.
- **Small ticks.** Each tick does one step per card and stops. A run is a series of ticks that can be interrupted, resumed and audited from the card thread.
- **Prompts written clean-room from specs.** See the provenance section of the top README and the record in `docs/implementation-plans/2026-09-28-fleet-board/specs/`.
