# State-machine follow-up, 2026-11-09

## Prior completion checked

Starting commit: `66b8133`, clean working tree on the local `fix/state-machine-ownership-20261109` branch. Three independent reviews inspected the implementation, previous audit, caller contracts and retained execution evidence before edits.

The prior four fixes are present. Retained logs corroborate 2,621 passing tests in 230 suites, the warnings-as-errors release build, and successful packaging. The existing bundle passes strict signature verification. It is stamped `54891fc-dirty`, because packaging preceded the commit; it is not a bundle stamped `66b8133`. The direct-file design-lint log counted zero scanned files, but the commit hook independently scanned five changed source files with zero hits. The earlier view guards remain source-reviewed rather than directly tested for their SwiftUI cancellation ordering. The notification regression exercised controller recovery; full NSApplication termination wiring was source-verified. Native keyboard-taking focus proof and installed-app inspection were explicitly not performed.

## Reconciled decision

All three reviews selected screenshot catalog refresh reconciliation. `ScreenshotTextIndex.refresh` promises to index new or changed items and drop removed items. `QuickViewModel.applyScreenshotScan` and `reloadScreenshotFiles` both replace the catalog and call refresh without cancelling OCR. The index instead ignored new pending work while a pass existed and allowed an old request to repopulate a removed entry.

The earlier audit's statement that callers must cancel describes an implementation limitation, not the intended contract. The recognition-mode control is different: `reindexScreenshotText` explicitly cancels then refreshes and is already protected by the previous change.

The bounded design keeps the existing pass owner and reconciles a latest pending queue. Unchanged OCR can finish; added or changed items run automatically; results absent from the current snapshot cannot publish. Snapshot identity includes path, file date, byte count and recognition mode. Explicit cancellation still relinquishes the pass and pending work. Progress describes the current catalog, including cached items, rather than only the original pass's pending batch.

UX gains reliable text search after rapid captures and removals. DX gains a single owner for refresh semantics with executable ordering tests. AX gains a local, documented transition contract instead of a hidden caller cancellation prerequisite. The trade-off is a small pending queue and snapshot comparison; no new framework, persistent format or UI control is introduced. Newly queued work waits for the current OCR call to return, preserving serialized recognition rather than launching overlapping reads.

## Remaining findings, ranked

1. **Update operation ownership.** Confirmed source-level transition defect: manual Check remains enabled while installing, and check functions can replace installation state; an older silent check can also publish late. No controlled transport/process reproduction yet. Highest remaining user-impact candidate, with a larger implementation/test seam than this fix.
2. **Busy-machine test stability.** This run observed deadline-based chat-scroll failures despite correct settled positions; isolated reruns passed. Replace wall-clock sampling assumptions with deterministic settling in a dedicated test-focused change before relying on the gate under load. No scrolling behavior change is justified by these traces.
3. **Attachment handoff ownership.** Cancelled watchers and waiters clean up by item ID. A simple round trip shares the same read and may be harmless; a harmful retry/transfer ordering remains unproven. Reproduce before editing.
4. **Application catalog publication.** Cancellation is checked before a main-actor publication hop. Stale publication is a hypothesis without controlled reproduction.
5. **JSONFileStore concurrency comment.** The comment claims decoder use is confined to the serial queue, while loadOrThrow decodes on its caller. The wording mismatch is real; decoder unsafety or corruption is not established.
6. **Availability cache, delayed focus and optional hotkey validation.** Lower-confidence or lower-impact concerns. No new evidence justifies expanding this change.

This is a dated audit report. Code and tests remain authoritative; it is not a runtime state registry.

## Verification record

Before the fix, the controlled OCR reproduction failed with three expected assertions: removed text was restored, added text was absent, and no second OCR request ran. This directly reproduces the refresh ordering defect through the index interface; it is a simulation of delayed OCR, not a live screenshot interaction.

- Targeted lifecycle suite: all 10 tests passed with warnings treated as errors. Coverage includes latest-catalog add/remove, repeated/duplicate snapshots, metadata/mode changes, empty catalog, callback reentry, explicit cancellation/recovery, empty OCR and byte-count ownership.
- Strict changed-file design lint: one changed source file scanned, zero hits.
- Independent implementation/contract review: no blockers.

The new ordering tests use controlled OCR and in-memory indexes. Existing screenshot-search tests separately cover persisted reload; corrupt-store and stored-mode tests cover recovery and mode persistence. No live screenshot interaction, native keyboard-taking proof, or installed-app inspection is claimed. No packaging changes are involved; the earlier packaged bundle remains the previous artifact.

The first full `make test` run executed 2,629 tests in 230 suites and failed with six issues in two existing chat-scroll suites. The scroll traces showed the correct bottom position but only six/seven identical observations before the 15-second settling deadline; the helper requires nine observations to establish eight stable comparisons. Concurrent compiler activity was observed. Independent source review found neither failing suite starts screenshot indexing. Both suites then passed unchanged in isolation: six tests, including all three answer lengths, in 27.8 seconds. This supports sampling starvation, not proof of an OCR-caused scroll defect, and does not erase the failed full-gate result.

Final validation on unchanged source:

- `make build`: release build passed with warnings treated as errors (115.3 seconds).
- Second `make test`, after release compilation finished: publish scrub clean; all 2,629 tests in 230 suites passed (89.1 seconds), including both scroll suites. This is the final gate result; the earlier load-sensitive failures remain recorded above.
- `git diff --check`: clean.

Delivery: committed on the local `fix/state-machine-ownership-20261109` branch. No push, release, packaging refresh, install or app launch. The installed app and prior packaged artifact were not replaced.
