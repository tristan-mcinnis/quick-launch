# Quit preservation: verified source, runtime checks pending

The installer and quit-preservation source changes are committed. **They are not installed.** The installed bundle remains build `27bd421`, which includes the earlier instruction-budget fix. No Raycast comparison has run.

| Change | Commit |
| --- | --- |
| Refuse installation unless process exit is confirmed | `e6b669b0257c87d30611c9ce0b0e8ed1dd3b3344` |
| Preserve final chat writes before allowing quit | `24441c12cd6b77b79730a162f6acdf0d2f994447` |
| Keep each overlapping submission's quit guard separate | `07f0428261ce5339bf9e47892a49b474a9a9a735` |

## The original quit path could leave the answer incomplete

A synthetic stream produced an 800-character checkpoint and a 200-character tail. The production quit path stopped the stream and drained the legacy history queue. An immediate synchronous read of the canonical archive still found 800 characters and a `streaming` status. The expected record held all 1,000 characters with a `cancelled` status. One test compiled, then failed on those two assertions.

The legacy history queue did not wait for canonical archive tasks. An existing canonical record also prevented the fuller legacy copy from repairing it on reload. This reproduces a durability gap at the production quit seam. It does not show that every real quit loses data.

## The fix waits for the writes that carry the answer

`AnswerDurability` keeps each unfinished terminal, projection and deletion write until it succeeds or a settled serialized operation proves the chat was deleted. Each retry uses its captured data. A later successful write cannot discard an earlier failed projection.

Normal completion registers its terminal write before the first suspension. Quit stops and captures both chat surfaces before awaiting either. It waits for their captured writes, then checks activity revisions and surface identity together. Failed saves, new activity and a missed two-second deadline refuse the exit. Late work cannot stop a new request. Attempt IDs guard the reply and reset state before a refused reply.

Each submit body now creates its own token before its first suspension. Finishing or cancelling an older submit cannot clear a newer submit's guard. Quit refuses while any preparatory submit remains. This closes a hole in the first published correction, where a shared Boolean could hide overlapping work.

Archive replay preserves newer stored values and adds missing data. Tool records use value identity: stored order and values stay, then distinct missing records are appended. An older replay cannot reverse a durable unpin. Prefix protection keeps terminal text and its receipt while retaining live-only attachments and tool records. The storage schema, package pins and unsent-draft policy are unchanged.

The installer requests a normal quit, then waits for confirmed exit. A still-running process, predicate error, missing command or wait failure refuses replacement. It no longer escalates to TERM or KILL.

## Independent checks and evidence

| Check | Result |
| --- | --- |
| Final focused gate | 141 tests in 11 suites; fresh compilation |
| Full app gate | 2,502 Swift Testing tests in 216 suites; 23 XCTest tests; no failures |
| Pinned shared package | 182 tests in 18 suites; earlier result reused after confirming unchanged pin and package hash |
| Installer helper | 13 tests, 23 cases with fake predicates; a private throwaway-Makefile check verified replacement refusal |
| Design, whitespace and privacy | Repository design ratchet: 0; strict checks on the ownership changes: 0; whitespace and privacy checks passed, including new/untracked files |
| Code and regression review | Independent PASS after the merge and submission-ownership corrections |
| Earlier base publication | Approved hooks passed 2,500 tests; remote main matched `24441c1`; GitHub-served source bytes matched local bytes |

The manual installer check is recorded in private `installer-correction/RECEIPT-20261022.md`; its probes are in `helper-probes-20261022.log` and `helper-probes-midwait-20261022.log` in that directory. It is separate from the committed Swift helper tests.

Earlier implementations passed tests but failed review. Rejected pre-publication versions were not published. Their failure logs and correction evidence remain private. Regressions cover mixed save outcomes, retry overlap, deletion rollback, completion timing, stale projections and metadata preservation.

The merge tests compare typed tool-record values, full receipts and attachment values from on-disk envelopes. Their fixture uses a fixed finish date through the production update method. This avoids codec precision noise without ignoring receipt fields. Fixture errors and genuine red runs were retained separately.

The ownership regression holds two submits immediately before their question writes. It cancels the older real Tab task, verifies that task's cancellation and cleared handle, waits for it to unwind, and requires quit refusal while the newer submit remains held. Under the original Boolean semantics, the corrected cancellation case produced three assertion failures. The final test adds the proper handle assertion and bounded waits; that earlier red is not claimed as a run of the final test bytes.

Test corrections are part of this record. One early test claimed cancellation without cancelling. A later composer fixture took a launcher path and hung before the seam; its exact row was not logged and it has no usable completion log. Source analysis points to an in-memory window-command failure, not an observed native action. Two full runs then failed the fixture's three-second waits despite focused passes. The fixture bounds were extended to thirty seconds without changing behavior assertions or the app's two-second quit deadline. The final independent full run passed. These bounds are not app-latency measurements.

## Runtime and comparison limits remain

- Native AppKit termination, a coalesced second quit, the refusal alert and real quit/relaunch recovery have not been exercised. The state and reply tests do not prove that native sequence.
- The synchronous `applicationWillTerminate` fallback does not await archive writes. Direct signal termination remains unverified.
- Tokens start when the submit body starts. A UI task queued but not yet entered into that body is outside this guard. A cancelled submit in a non-cancellation-aware await keeps its token until it unwinds, so quit can remain refused during that wait.
- The deterministic test seam is immediately before `submitDurableMaterial`, not inside `ChatArchive.submit`. Coverage of the archive await follows from the token's lifetime in code. Tests exercise two overlapping submits, not three or more.
- Replay ordering is per view model. General arbitration between two current snapshots is unchanged. Same-length divergent text in a current cross-view projection can still replace stored text. Rename and pin tasks remain outside the answer-write tracker.
- Memory-only drafts remain memory-only. No new draft retention or recovery store was added.
- Opt-in native focus and performance checks were not run. Compiler warnings remain. A strict whole-test-tree lint also reports three pre-existing hits in `FormattedPasteTests`, `LightModeEnforcementTests` and `OverlayRenderProofTests`; those files were not changed.

The native desktop intent gate still blocks the head-to-head. The protocol remains proposed, the held-out inputs remain sealed, and comparative attempts remain Quick Launch 0/60 and Raycast 0/60. These fixes establish no competitive win.

## Rollback preserves separate choices

To undo ownership and durability while keeping the safer installer, revert in reverse order:

```sh
git revert 07f0428261ce5339bf9e47892a49b474a9a9a735
git revert 24441c12cd6b77b79730a162f6acdf0d2f994447
```

The installer has its own revertable commit, `e6b669b0257c87d30611c9ce0b0e8ed1dd3b3344`. Reverting it restores forced termination, so retain it unless that behavior is deliberately wanted. Any app replacement still needs a clean, reviewed build, preserved signing identity, a rollback bundle and confirmation that work can safely stop.
