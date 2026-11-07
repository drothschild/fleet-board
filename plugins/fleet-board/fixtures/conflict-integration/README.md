# Conflict integration exercises

Read the current manager instructions and apply `manager-scenarios.json` as dry-run inputs. Commands not marked failed succeed. Record an array with name, fixer_findings, ordered actions, final_state, combined note_patch, progress and review_dispatched_this_action. No real board or GitHub actions belong in this exercise.

Generate reviewer histories with `python3 plugins/fleet-board/tests/make-conflict-review-fixtures.py <new-scratch-directory>`. Apply the current reviewer modified-test policy to the commits in `cases.json`; independently reconstruct each merge, run its named test and restore each implementation mutation. Record name, classification, reason, evidence, test_passed and mutation_killed.

Save the results as `pr215-manager-behavior.json` and `pr215-reviewer-behavior.json` in one result directory. Validate them with `bash plugins/fleet-board/tests/check-conflict-integration-behavior.sh <result-directory>`. This checker validates recorded exercise artifacts; it does not execute the roles itself. Contract checks run separately through `test-conflict-integration-contract.sh`.
