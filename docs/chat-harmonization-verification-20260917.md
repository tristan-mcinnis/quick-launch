# Chat harmonization verification

17 September 2026. Working evidence, **not release acceptance**.

Approved scope: `chat-harmonization-plan-20260917.md`.
No app has been installed or released by this implementation run yet.

## Launcher

Maker reports 13 new hidden/learning tests and three related batches of 205,
206 and 152 tests passing, plus a fresh build and strict design lint.
The regression covers successful Voice Memos selection, input captured before
launch clears it, persistence after reload, and no learning on failed launch,
highlight or cancellation. Final combined-tree regression is still required.

Independent image review inspected both actual offscreen proofs:

- `/tmp/quick-launch-render-proof/launcher-hidden-items-dark.png`
- `/tmp/quick-launch-render-proof/launcher-hidden-items-light.png`

Both show eight legible filters, five hidden rows, per-row Restore, Restore All,
two Source unavailable labels, and a matching footer. No clipping or exposed
clipboard/chat body was observed. Native keyboard-focus checks remain pending.

## Shared core

Independent fresh run:

`swift test --package-path Packages/HouseChatCore --scratch-path /tmp/house-chat-core-independent-20260917`

The original 89 tests passed. Adversarial probes nevertheless found blockers:

- Reference collection skipped corrupt/unsupported owners, allowing cleanup to
  delete their last attachment copy.
- Concurrent archive instances could misclassify a newly created directory as
  unsafe.
- Bare search/latest/news wording widened externally grounded file questions.
- The component initializer for endpoint metadata did not strip query secrets.
- Unknown nested schema fields were not uniformly preserved.
- Document selection omitted separators from its stated request budget.

Repairs add fail-closed reference scans, a shared filesystem root lock,
conservative retention of failed-commit blobs, strict external-target matching,
endpoint normalization, nested unknown fields and exact budget accounting.
All request blobs, including request snapshots, can now enter through the
coordinator's locked commit. Direct archive writes remain outside that lock's
guarantee and must not be used by app send paths.

Independent extraction probes also found falsely complete OCR-capped PDFs and
raw JavaScript leaking from truncated HTML. The maker repaired both and added
regressions, actual-read package caps, flat RTFD handling and cancellable Vision
work. The timeout is an honest cooperative cancel-and-join deadline, not a hard
kill of an uncooperative native operation.

Final independent package verification passed 167 tests: 118 core and 49
document tests. Separate public-API probes passed 150 core assertions and 165
document assertions with no functional failures. They covered cross-process
locking, fail-closed cleanup, source gating, snapshot ownership, schema
round-trips and actual scattered OCR coverage. A remaining stale README count
was removed. Endpoint metadata deliberately retains only sanitized whitelisted
fields; content and other stored metadata preserve their unknown fields.

This accepts the shared package's tested boundary, not its app callers. The
original green counts alone were not accepted. Probe sources remain under
`/tmp/house-chat-verify-20260917` and `/tmp/house-documents-verify`.

## Retrieval

Read-only diagnostics reproduced the original Quick Launch failure: the VPS
reader expected `VAULT_INDEX_READER_DATABASE_URL`, but its environment only
provided `HERMES_READER_DATABASE_URL`. The credential itself was not missing.

Tristan explicitly approved adding the alias. The remote worker checked that
the existing `neondb_reader` role had SELECT-only table grants and no database
or schema creation privileges. It added one alias line atomically, preserving
all original lines, owner and 0600 permissions. A private rollback copy stays
beside the original environment file. No credential values entered this
record; no database contents or permissions were changed.

Worker live probes passed current, portfolio, scope and flat-project history.
A separate parent probe confirmed that the original environment error was gone,
but found a further nested-project defect: scope resolves `personal/stack`,
while history rejected that canonical ID as an invalid flat slug.

Tristan separately approved repairing the local and server validator. It now
accepts slash-separated valid segments and still rejects traversal, absolute
paths, empty segments, quotes, uppercase and oversized segments. The server
patch matches the locally tested source, with a private pre-edit backup. A fresh
parent run passed all nine Python tests and independently confirmed:

- `history --project personal/stack`: exit 0, `ok: true`, two requested rows,
  1,019 ms.
- `current --project personal/stack`: exit 0, `ok: true`, six evidence rows,
  1,643 ms.

The existing fuzzy SQL predicates have a latent future nesting risk; measured
current matches do not cross canonical project roots. SQL hardening was not
part of the approved validator patch.

The Quick Launch adapter now resolves history scope before calling history and
classifies available/no-match/degraded/unavailable. The RTI adapter now resolves
`code/vault-search/src/cli.ts`, forwards scope and normalizes returned paths.
Maker reports 86 related Quick Launch tests and a standalone RTI typecheck.
Final consumer status rendering and current full suites remain pending.

## RTI

The first integration stage compiled and its maker reports 570 tests passing.
That stage did not include the Chats library, shared extractor, full request
snapshots or all composer controls. It is not full-plan acceptance.

Parent review found `ChatThreadStore.thread` treating every load error as
missing; this was repaired to catch only an actual missing record.

A later independent call-site review found more serious integration gaps that
helper tests did not exercise: composer attachments lost their byte payloads,
live follow-ups did not refresh retained sources, image-only captures lacked
archive refs, cancellation could target the newly resumed chat, session links
were creation-only, and projection deletion had no caller. The external
`read_document` tool was also missing from the source-only gate. A fresh maker
repaired the actual runtime and added injectable controller-level checks.
Further review caught retained sources being added before the policy decision;
the caller now resolves fresh-source scope first, composes the permitted set,
and writes that same decision to the receipt. Tests cover fresh-only turns,
explicit comparisons, retained-image follow-ups and cancellation between rounds.

Independent current-source Xcode execution passed on 17 September:

- RTITests: 647 tests, 1 skipped, 0 failures.
- RTIRenderTests: 176 tests, 0 failures, including 19 actual-controller cases.
- Log: `/tmp/rti-final-test-151334.log`.
- Result bundle: `/tmp/rti-final-151334.xcresult`.
- Render proofs: `/tmp/rti-render-proof/`.

After that run, the parent made one display-only correction: picked mention
paths now count as fresh sources in the pre-Send image preview. Final compilation
of that one-line change passed in the same acceptance build directory:
`/tmp/rti-final-buildfor-testing-152631.log`. No test was re-executed on that
one-line revision, so compilation is not described as another 823-test pass. Hand-typed unresolved mention tokens remain
a preview limitation; the actual resolved send and receipt enforce source scope.
No installation or recording restart occurred. This is test evidence, not an
installed-build acceptance.

## Quick Launch integration

The canonical archive's 24 tests pass, including migration, restart after
original deletion, shared references, tombstones, corruption and metadata
serialization. The actual submit/completion sequence needs separate evidence.
Independent static review found mismatched live/durable assistant IDs, a
synthetic rather than actual provider-body snapshot, incomplete timings,
pre-Send image-routing labels that missed tray/history images, and `/new`
queued behind an active stream. These are being repaired in the caller with
real view-model flow tests. A final static review closed those caller defects:
each provider round now persists its actual body before network execution,
tool rounds carry explicit outcomes, available usage is recorded, and route
preview/send share a resolver that prefers the selected known image-capable
model. A missing credential blocks rather than silently swapping providers.

Settings now states keep-all retention instead of offering obsolete age/count
controls. Confirmed Delete all preflights every canonical owner, cancels active
sends, tombstones records, collects only unreferenced bytes and reports failures.
Legacy history keys remain decodable for rollback and the compatibility cache;
they no longer hide or prune canonical chats.

The final review found a text-only blocked route incorrectly labelled as an
image fault. The parent corrected `hasImages` and added the label assertion.
A final compile also caught a shadowed test-helper name in the three newest
tool-outcome tests; the parent qualified the helper call. A fresh independent
`swift test --disable-xctest` then passed 2,378 tests in 200 suites on those
exact bytes. Evidence: `/tmp/ql-final-swift-testing-152458.log`. The native
palette-focus suite and its three chooser/action-search checks were skipped by
their explicit environment gate; XCTest was excluded, not counted as passing.

The resize test was measuring new composer chrome as transcript ink; its probe
now measures the real composer height. The fixed-width transcript was correct.
The trim fixture now proves both fresh-source-only and explicit-comparison cases.
Unchanged TypeToClick XCTest sources passed eight isolated runs, but competing
AppKit processes reproduced intermittent global-input failures. These tests
are excluded from the background final run and require a quiet desktop window;
they are not silently counted as a fresh combined-tree pass.

A separately approved, prebuilt, quiet-desktop window then passed all 23
TypeToClick XCTest cases and all three gated native focus cases. The two
commands took 8.9 seconds in total, with no rebuild or retry:

- `/tmp/ql-final-native-xctest-typetoclick.log`
- `/tmp/ql-final-native-focus-proof.log`

This closes the excluded native checks without mixing them into the background
suite's count.

No application-level release claim is made from archive helper tests.

## Test isolation correction before installation

Backup inspection found that three older `OverlayParityTests` cases wrote to
`ModelPreferenceStore.shared` and reset the live model-visibility/reasoning
preferences file. Tristan confirmed he had made no customizations, so defaults
were the intended state and no custom choices needed recovery. No chat content,
API keys or catalogue entries were stored in that file. The tests now use
memory-only stores; picker and refresh methods explicitly use the injected
store. Independent re-execution passed all 105 affected tests in five suites,
with the live file's hash, size and mtime unchanged:
`/tmp/ql-final-di-161346.log`.

The RTI proof harness also initialized its production mode store, which loaded
and rewrote `modes.json`. User-added modes survived the load/save path, but this
was still an inappropriate test write. Memory-only mode stores now flow through
the controller, overlay and settings proofs. The production default store and
its migration semantics remain unchanged. Two independent 83-case runs passed
all assertions but caught additional fixture paths still touching the singleton.
Those writes were semantically identical to the rollback copy (four unchanged
mode records); only JSON key order changed. Direct header fixtures now inject
memory stores. The last path was a stored-property `.shared` initializer running
before `SettingsView` assigned its injected argument. That eager initializer is
removed; the production default remains on the initializer argument. The final
fresh-process Settings run passed all 15 tests with the live modes hash, size and
mtime unchanged, and config untouched. Evidence:
`/tmp/rti-final-di3-163200.log`, `/tmp/rti-di3-163200.xcresult`.
The isolation correction is independently verified.

A separate concurrent commit, `3a14e4a` (Recall schema 3), was preserved rather
than overwritten. Its 14 RecallCLI tests passed independently:
`/tmp/ql-final-recall-162950.log`.

## Packaging and remaining gates

Both app build paths will stamp the shared package owner commit and source
SHA-256 before signing. Five fixture-only Python tests pass for the fingerprint
helper; both modified shell scripts pass syntax checks. RTI installation also
requires clean shared-package sources, not merely a clean RTI checkout.

Both consumers pass strict changed-source design lint (75 Quick Launch files;
34 RTI files), and the design registry is clean (17 components, 10 repos).
Independent review of six final RTI minimum-size/library/composer images found
no clipping or overlapping controls in either theme. Secondary light-theme
metadata contrast remains a design-system limitation, not a new geometry bug.

Independent final Quick Launch visual review also passed eight light/dark
composer, receipt, retained-material and hidden-item proofs. No clipping,
overlap or hidden clipboard/chat content leak was observed. A truncated model
label leaves a cosmetic closing parenthesis; it is not a route or storage fault.

Rollback app/data snapshots are retained, owner-only and Git-ignored, at
`quick-launch/build/rollback/20260917-161031` and
`rti/build/rollback/20260917-161031`. Post-install receipts belong there too.

Code and test verification gates are closed. Remaining release operations:
source provenance, clean commits, installation and installed-build checks. Tristan approved committing and installing both apps, with no
push. The RTI installer now rechecks idle state immediately after its build and
refuses active, paused, busy or unverifiable state. Both installers refuse to
replace a process that has not exited; neither force-terminates it. Then verify
the installed commit, code signature and shared-source stamps.
