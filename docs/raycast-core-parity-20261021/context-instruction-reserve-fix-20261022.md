# Grounded-instruction reserve correction

## Status
Independently reviewed and tested. Not installed during this checkpoint. This is an internal correctness fix, not evidence that Quick Launch is better than Raycast.

## Defect and change
The attachment budget counted the surface instruction, but the model request also carried the grounding directive and its separator. In the reproduced custom-instruction case, the request instruction was 184 UTF-8 bytes and the reserve counted 15. The 169-byte difference allowed 101 extra attachment characters under the existing budget formula. An empty surface instruction also omitted the 167-byte grounding directive.

The model request and its reserve now use the same instruction composition: assistant instruction, surface instruction and grounding directive, with the provider's blank-part and separator rules. The attachment-strip estimate uses the resolved route rather than deriving another provider/model pair. No tool, source-scoping, extraction, context-window discovery or CLI-grounding policy changed.

## Independent checks
- Before the fix: 5 of 6 regression tests failed; the ungrounded control passed.
- Final focused suite: 9 tests passed. Tests use isolated state, synthetic sources and mock transport; the wire-body service is rebuilt from the real send-path messages, not captured from a live provider.
- Full gate: Swift Testing 2,433 tests/209 suites; XCTest 23 tests, no failures; scrub clean.
- Pinned HouseChatCore v1.0.0: 182 tests/18 suites passed, checkout unchanged.
- Design ratchet: 0 hits against baseline 0. Patch whitespace check clean.
- Independent semantic recheck:PASS. Changes are three production files and one new test file, `Tests/ChatInstructionReserveTests.swift`.

Raw red/green and independent gate logs remain in the local comparison evidence directory, under `context-reserve-fix/` and `verification-20261022/`.

## Limits
- No real-model overflow was demonstrated. This fixes instruction-byte accounting, not exact token-window planning.
- The pre-Send strip remains an estimate. It lacks the asynchronous assistant instruction and expanded/enriched prompt. It also does not pass saved-action route overrides; the user-visible case still needs testing.
- The strip test uses wide over/under margins. It does not demonstrate a previously divergent route or a latency gain.
- The command-line lane retains its unlimited attachment budget. Its surface instruction reaches the process only when the command has the system-prompt placeholder.
- The current send path inserts at most one assistant system message. A future second system message must also enter the reserve.
- `budgetCharacters` changes by construction across this fix. Do not interpret that change as a quality score.
- The three opt-in performance/native-focus suites (eight tests) were not run at this checkpoint. No native UX, speed or competitive verdict follows.

## Rollback
Revert the dedicated instruction-reserve fix commit with `git revert d419052d87dfe11699fde78ef75a3b220700a5c0`. This checkpoint changes no settings schema or stored chat data. The installed app remains the measured baseline until a separately checked installation.
