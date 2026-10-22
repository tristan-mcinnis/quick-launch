# Raycast core workflows: shipped-artifact evidence ledger

Evidence pass 2026-10-21/22; review corrections 2026-10-22. Read-only static analysis of the
installed Raycast 2.8.2.0 bundle. No app launch, no UI control, no network capture, no
debugger or process-memory read, no preference, history, Keychain or profile read, no
environment dump. No vendor code, binary or screenshot is stored in this repository; raw REA
records and full extractions stay outside Git in the local comparison evidence directory
(`rea/`).

Purpose: supply the behavioural facts a live head-to-head needs, and name mechanisms worth
testing. This document makes **no** product-superiority claim and no feature-parity claim.
Static existence is not runtime behaviour.

## Evidence classes used below

Every claim carries one of three labels. The label describes what kind of record supports the
claim, not how strong the claim is.

| Class | Meaning |
| --- | --- |
| **SG** | A sealed REA record covers the module, **and** a specific retained semantic-graph node (or literal) for the construct is cited by ID. The node's existence is machine-checked; the semantic reading of that node is still mine. |
| **RS** | A sealed REA record covers the module bytes (the module was one of the caller-selected sources, and its SHA-256 is in the record's selection), but no retained node for this specific construct was found in the parsed JSON. The fact is a direct read of exactly those sealed bytes at the stated offset. |
| **SO** | The module is outside all four REA selections. No REA record covers those bytes; the fact is a direct read only. |

Locators are byte offsets into the named module, with the module's full SHA-256 in Appendix A.
A hash prefix in the body is a locator convenience; Appendix A is the reproducible identity.

## 1. Artifact identity, re-measured

| Item | Value | How measured |
| --- | --- | --- |
| App | `/Applications/Raycast.app` | path |
| Version | 2.8.2.0 (CFBundleVersion 0) | `PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist` |
| Bundle id | `com.raycast.macos` | same |
| Executable mtime reported by `ls` | 2026-10-16 03:01 | `ls -la Contents/MacOS/Raycast` |
| Main executable | 16,208,512 bytes, SHA-256 `9d823200b6fc4803c9a669d295035654598b7c0655434bc86f27f71493af3076` | `stat -f%z`, `shasum -a 256` |
| Main executable (Mach-O facts) | arm64, minOS 26.0, SDK 26.5, UUID 5853690E-636B-3034-B833-F456C524E84B, 4,796 imports, 2 exported symbols | REA `inspect_macho` `ev_d9060ec97878d387d960f8d355beed56ebff9982310326ff252dcfa01e74cee9` |
| Host dylib | `Contents/Frameworks/libraycast_host.dylib`, 5,496,496 bytes, SHA-256 `94af755b2402cf4087288f7834887c13628f8eaa171080f281eb88954b0e5d3e` | same tools |
| Host dylib (Mach-O facts) | arm64, minOS 26.0, SDK 26.5, 194 imports, 181 exports | REA `ev_697f0cf6f1168fe5d6395dccb9b4efd24b686794d4edf7057bb6837e24693d15` |
| Frontend application root | `…/Resources/macos-app_RaycastDesktopApp.bundle/Contents/Resources/frontend` | path |
| Frontend root digest | `9dd06751e0f25723fca6bc5be5ada528f894db7bb00edcead8edb3df56e0b258` | `normalized_result.root_artifact_sha256`, identical in all four JS records |
| Inventory identity | manifest `agm_dbf168486b10f511d6caab49099ba039e7ab83a583b24ea78d584877247e3573`, graph `0f7dcf50106c2178529ec2ec1475ab8ba18c9098f4f0ee5a863ee657355ec65f` | `inventory_manifest_id`, `inventory_graph_sha256` |
| Backend | `…/Resources/backend` (Node 22.23.3 shipped as a tarball, `.node` addons, `index.mjs`) | `ls` |

### File-count reconciliation (corrects an earlier mixing of three numbers)

- `1366` = every entry in the `frontend/` directory: 566 `.js`, 9 `.html`, 468 `.png`,
  158 `.css`, 138 `.svg`, 13 `.jpg`, 9 `.webp`, 3 `.woff2`, 2 `.mp4`. Sum: 1366.
- `566` = JavaScript modules, and also the count of `module` nodes in each REA graph.
- `575` = REA `statistics.relevant_files`, i.e. the analysable sources: the 566 `.js` plus the
  9 `.html`. It is not a count of all files, and not a count of analysed files.
- Per-run analysed files were 11, 6, 3 and 3 (the selections); 564–574 files were left
  unselected in each run, which the records state as a limitation.

### Layer map, with what the export count does and does not prove

1. **Native shell** (Swift/ObjC, AppKit + Carbon + InputMethodKit, minOS 26). Stripped: 2
   exported symbols, 4,796 imports. Its imports include accessibility (18 `AXUIElement*`,
   5 `AXObserver*`, `AXIsProcessTrusted`), pasteboard (18 `NSPasteboard*`) and synthetic
   input (32 `CGEvent*`) symbols, plus `NSWorkspace`/`NSRunningApplication`.
   **Therefore the main binary is not proven to be a thin shell.** It is where
   accessibility, pasteboard and event synthesis live, which are exactly the lanes behind
   `applications.getSelectedText`, the `workspace.capture*` family and paste delivery. The
   fact that it exports almost nothing only means function-level attribution is unavailable
   from the symbol table; internal Swift code can hold logic without exports.
2. **Rust host** (`libraycast_host.dylib`, uniffi). 181 exports, grouped: 24 exported
   methods, 11 record types, 6 enums, 5 errors, 5 interfaces, 3 free functions, 2
   constructors, 53 FFI scaffolding functions, 71 checksum/clone/contract helpers, 1 namespace
   meta. The 24 methods name exactly four objects: `Coordinator`
   (`start`, `stop`, `get_state`, `send`, `notify`, `note_power_transition`,
   `note_windows_open`, `boost_execution_speed_for`), `EventHandler`
   (`on_request`, `on_notification`, `on_failure`, `on_backend_log`,
   `on_backend_performance_log`, `on_backend_stall`, `should_record_backend_trace`),
   `LogHandler` (`on_log`, `on_panic`) and `NativeSentryClient`
   (`set_user_id`, `set_telemetry_tags`, `add_breadcrumb`, three `test_*` helpers) plus
   `SentryFrameResolver.resolve`. The 11 records are named exactly: `BackendEnvironment`,
   `Config`, `CoordinatorResponseTiming`, `CoordinatorSendResponse`,
   `DistributedTracingMetadata`, `ResolvedManagedFrame`, `Secrets`, `SentryEnvironment`,
   `SentryTrace`, `TerminationOutcome`, `WorkspaceEnvironment`. The 6 enums are
   `CoordinatorState`, `EngineConfig`, `InboundRequestDestination`, `LogLevel`, `NodeEnv`,
   `PowerTransition`; the 5 errors are the four start/stop/send/request errors plus
   `NativeSentryClientError`. **What this proves:** the Rust layer's public surface is backend
   supervision, request transport, logging and crash reporting. **What it does not prove:**
   that no AI, prompt or paste logic exists in Swift or in the Node backend.
3. **Node backend** (`backend/`, Node 22.23.3) reached over IPC.
4. **JS frontend** (575 analysable sources). AI surfaces, composer, attachments, prompt
   composition, model picker and key handling are here.

**Unresolved lane.** The frontend calls host IPC methods such as
`ipc.host.workspace.captureScreen` / `captureScreenArea` / `captureFocusedWindow` /
`captureAiContext`, `ipc.host.applications.getSelectedText` / `selectAll` /
`getFrontmostWindowContext`, and calendar reads. Their implementation was not resolved: the
native binary is stripped, no Swift function was decompiled, and no IPC channel catalogue was
recovered (REA reported zero literal channels because the transport is a proxy). Every claim
about capture, selection or paste *implementation* is therefore open; the claims below are
about the caller side only.

### Version drift

The 2026-10-15 record (`docs/raycast-quick-ai-20261015/investigation-index.json`) recorded
Raycast 2.8.0.0 with executable SHA-256 `12b9b581f1f0c9fac42f9a59d936aa9ded963ee7a6af15626985ec96311b85fa`
and per-module `source_digests`. That prior record — not this pass — is the source for the
2.8.0 identity; the prior binary was not re-measured here. Comparing the prior record's module
digests with the current bytes shows three modules unchanged:
`quick-ai-start-new-chat.logic` (`2cd0ff5c89f3e00eb7a27d2fd9564a9a2e39e52a2a71e4112010d948d807fcb3`),
`show-main-window-for-quick-ai` (`033fdb95f15a95f7c0c70f75090812c690d66f1b7a87f3ebd156884e2698cb30`),
`composer-action-handoff` (`dc7b5a623720fb6d266f15061f1e09f534cbf48fe389ec575f9afd2a949cbea2`).
All other modules cited here differ from the prior record.

## 2. REA records and what each one actually covers

| Record | Selection (requested paths) | Analysed | Notes |
| --- | --- | --- | --- |
| `ev_abdd2d16cf31fb52c022c7382213dffcce99d44609851d64838f6bc24ecd1173` | 11 files: quick-ai-entry, quick-ai-services, quick-ai-start-new-chat.logic, show-main-window-for-quick-ai, send-to-quick-ai, send-to-ai-capture, composer-action-handoff, ai-access-policy, quick-ai-footer, quick-ai-autocomplete-action-options, attachments | 11/575 | 6,707 AST nodes, 0 parse failures, 564 unselected |
| `ev_60b5a395959c06c3fded627f165eb8f4978936e24e2d38c73f9a35f8f33d253c` | 6 files: ai-chat-window, ai-chat-window-services, ai-chat-handoff, ai-window-context, chat-layout, use-ai-chat-router | 6/575 | 9,625 AST nodes, 569 unselected |
| `ev_c844f0731b20e3af4c124ae80cf54d628d657459ed530e702aa7ce8b8300dea4` | 3 files: runtime-model-submenu, reasoning-effort-options, runtime-model-ordering | 3/575 | 2,420 AST nodes, 572 unselected |
| `ev_94b1921869243a1a4470cdd9c049c6e6cf33886ded86bbb777ef113f5974d864` | 3 files: shortcuts, key-down-handler, escape-key-closes-window | 3/575 | 1,480 AST nodes, 572 unselected |
| `ev_d9060ec97878d387d960f8d355beed56ebff9982310326ff252dcfa01e74cee9` | main Mach-O | — | imports/exports not exhaustive (stripped) |
| `ev_697f0cf6f1168fe5d6395dccb9b4efd24b686794d4edf7057bb6837e24693d15` | host dylib | — | 181 exports, 194 imports |
| `ev_d195e061b1c46e1820a9f2740e9b2dbf1e6554106727a19f77df8333156e0667` | compose-ai-command-prompt (1 file) | 0/575 | **partial observation inside a failure envelope**, see below |

All four JS records state: sources parsed as inert text, bootstrap never executed,
relationships through unselected sources unknown, graph coverage `partial`.

**The composition-module result, stated precisely.** The saved record `js-C.json` is a
`provider_timeout` envelope (category `timeout`, `details.timeout_ms` 900000) whose
`details.partial_observation` still carries a valid evidence record
`ev_d195e061…` with inventory identity (`agm_dbf168…`, root digest `9dd06751…`), a
`semantic_graph` of **566 module nodes and 0 relations**, `statistics.parsed_javascript_files`
0 with `skipped_javascript_files` 1, and a coverage limit
`javascript_analysis_worker_timeout_ms` = 900000. So: the file **is** in the inventory, the
run **is** recorded, and there is **no accepted semantic record for that file's contents**.
Those three states are different and are kept separate here. The recorded 900000 is a
configured timeout value, not a measured wall time; no wall time was captured. A second
attempt (node caps 3,000) reached the parse/project phase and stopped progressing; the owner
stopped it and no record was written. Prompt-grammar claims (R28–R30) are therefore **SO**
reads of those bytes.

## 3. Coverage assignment

Claim → class, with the record that applies. Where the independent review named a narrower
set of record-backed claims, the difference is shown explicitly and grounded in parsed JSON.

| Claim | Module(s) | Class | Record | Node / locator |
| --- | --- | --- | --- | --- |
| R1 | host dylib | SG | `ev_697f0cf6…` | export list (24 methods of 181 names) |
| R2 | quick-ai-entry | SG + RS | `ev_abdd2d16…` | `jsrg_node_59fb04cc…` (`admitted`); status literals not retained |
| R3 | quick-ai-entry | SG + RS | `ev_abdd2d16…` | `jsrg_node_13ab99ce…` (`stillPresented`) |
| R4 | quick-ai-entry | SG | `ev_abdd2d16…` | property-slot `jsrg_node_3dec9564…` |
| R5 | quick-ai-services | RS | `ev_abdd2d16…` | `personalizationEnabled` not retained |
| R6 | quick-ai-services | SG + RS | `ev_abdd2d16…` | promise node `jsrg_node_8f2b3b39…` |
| R7 | show-main-window, quick-ai-entry | SG | `ev_abdd2d16…` | `jsrg_node_283f49c0…`, `jsrg_node_54f50e6c…` |
| R8 | window-handoff | SO | none | `window-handoff-fMu7u2Zy.js@363` |
| R9 | autocomplete-options; main-window | RS + SO | `ev_abdd2d16…` | `google` id not retained; "Ask in Launcher" in main-window |
| R10 | start-new-chat.logic; ai-chat-window-services | RS | `ev_abdd2d16…`, `ev_60b5a395…` | duration literals not retained |
| R11 | send-to-ai-capture, send-to-quick-ai | SG | `ev_abdd2d16…` | `jsrg_node_15e448da…`, `jsrg_node_141a5ea1…` |
| R12 | composer-action-handoff | SG | `ev_abdd2d16…` | property-slot `jsrg_node_51db2178…` |
| R13–R18 | main-window | SO | none | six separate locators in §4.3 |
| R19–R22 | turns, turn-projection | SO | none | locators in §4.4 |
| R23 | attachments | SG | `ev_abdd2d16…` | literals `jsrg_node_40085919…`, `jsrg_node_5b1485d6…`, `jsrg_node_1b1280e1…` |
| R24 | composer-screen-awareness.logic | SO | none | `composer-screen-awareness.logic-DW16s9Kn.js` |
| R25 | file-attachment | SO | none | `file-attachment-Bp3qkNDN.js@907` |
| R26 | chat-composer-add-menu | SO | none | `chat-composer-add-menu-DgxDy8kf.js@3075` |
| R27 | composer-pending; main-window | SO | none | both outside caller-selected sources; main-window `@184217` |
| R28–R30 | compose-ai-command-prompt | SO / blocked | `ev_d195e061…` inventory only | offsets `@5943`, `@8466`, `@7081` |
| R31 | shortcuts | SG | `ev_94b19218…` | property-slot `jsrg_node_31e2f9eb…` |
| R32 | key-down-handler, escape-key-closes-window | SG | `ev_94b19218…` | `jsrg_node_458bfcb3…`, `jsrg_node_b8ee3357…` |
| R33 | empty-state-default | SO | none | `@29380`, `@29222` |
| R34 | reasoning-effort-options | SG | `ev_c844f073…` | `jsrg_node_291799aa…`, `jsrg_node_c984a5d3…` |
| R35 | runtime-model-submenu, runtime-model-ordering | RS | `ev_c844f073…` | `quick_ai` and sentinel literals not retained |
| R36 | composer-pending-config | SO | none | inventory identity only; direct source locator `@696` |

**Where this table differs from the review summary.** The review named R1, R2, R4, R31, R34
and R35 as the record-backed claims. Parsed-JSON node lookup also finds retained nodes for
R3 (`stillPresented`, 4 hits), R6 (`Promise.all` aggregate), R7 (`warmupMainWindow`,
`showMainWindow`), R11 (`checkPermission`, `hideMainWindow`), R12
(`screenAwarenessContexts`), R23 (three literals) and R32 (`stopImmediatePropagation`,
`escapeKeyClosesWindow`). R35 is the reverse case: its module is in a sealed record, but the
`quick_ai` and sentinel string literals are **not** retained as nodes, so it is RS, not SG.
No claim in this ledger is labelled SG without a node ID that can be looked up in the saved
JSON.

## 4. Evidence ledger

Locator format: `module.js@byteoffset`. Full identity in Appendix A.

### 4.1 Backend supervision and execution-speed control

**R1 [SG]. The Rust host supervises a Node backend and can raise its execution speed for a
bounded period.** Observation: the exported method set is `Coordinator`
(`start`, `stop`, `get_state`, `send`, `notify`, `note_power_transition`, `note_windows_open`,
`boost_execution_speed_for`) plus the `EventHandler`, `LogHandler` and `NativeSentryClient`
interfaces; records include `CoordinatorResponseTiming` and `CoordinatorSendResponse`.
Evidence: `ev_697f0cf6…` export list.
**Limits:** static only. Which policy value is passed to the boost, which events trigger it,
and whether it affects first-token latency are unknown; no runtime call was observed.

Record: `ev_697f0cf6…` (host export list).

### 4.2 Quick AI admission, rejection, dismissal, promotion

**R2 [SG + RS]. Launch is two-phase: presentation is optimistic, admission is asynchronous.**
A retained node is the `admitted.then(…)` call on the launch result
(`jsrg_node_59fb04cc…`, `quick-ai-entry-B_WAMKaf.js` col 1443), which is what makes admission
asynchronous after the launch call returns. The two non-success statuses named in the caller
(`superseded`, `rejected`) are not retained as nodes, so that part is RS at
`quick-ai-entry-B_WAMKaf.js@1133`–`@1622`. Read as: on the success path the surface navigates
and shows before admission settles; admission later resolves with
`{accepted:false, error.code, stillPresented}`.
**Inference:** a user can type into a window whose message will later be refused.

Record: `ev_abdd2d16…`; node `jsrg_node_59fb04cc…`.

**R3 [SG + RS]. Rejection has three recoveries, chosen by `stillPresented`.**
Node `jsrg_node_13ab99ce…` (`stillPresented`, col 3379). On rejection a toast titled
"Message could not be sent" carries the error message; if the surface is still presented and
the entry was Root Search, the composer is reset with the original text and `send:false`;
the AI-Command path re-presents the surface without restoring text. Locators
`quick-ai-entry-B_WAMKaf.js@1897` (`stillPresented`), `@1404` (`cancelPendingLaunch`).

Record: `ev_abdd2d16…`; node `jsrg_node_13ab99ce…`.

**R4 [SG]. A new launch cancels the previous pending launch; a prefill view never auto-sends.**
Property-slot `jsrg_node_3dec9564…` (`cancelPendingLaunch`). The prefill path calls it, then
pushes text with `send:false`; the query path trims and, when empty, cancels and presents an
empty composer instead of sending.
Locator: `quick-ai-entry-B_WAMKaf.js@1404`.

Record: `ev_abdd2d16…`; node `jsrg_node_3dec9564…`.

**R5 [RS]. Quick AI runs with a reduced surface configuration.** The per-launch configuration
sets model/effort/routing defaults, optional `highlightEdits` with an `inputText` slice, and
explicitly `personalizationEnabled:false`, `toolSearchEnabled:false`,
`skillLoadingEnabled:false`.
Locator: `quick-ai-services-fArxFyDT.js@1603`. Unchanged in substance from the prior pass, so
it is a stable design choice rather than a new one.

Record: `ev_abdd2d16…` (module sealed; no node for this construct).

**R6 [SG + RS]. Service initialisation is idempotent, serialised, and does work before first
use.** Node `jsrg_node_8f2b3b39…` is the aggregated await over
`lifecycle.start()`, extension-summary warmup and model-catalog refresh; the memoisation and
serialiser are RS at `quick-ai-services-fArxFyDT.js@3244`. Failure sets a shell status of
`error` instead of throwing to the caller. `pagehide` disposes the service (RS, `@2959`).

Record: `ev_abdd2d16…`; promise node `jsrg_node_8f2b3b39…`.

**R7 [SG]. Reveal is warmed before it is shown.** Nodes `jsrg_node_283f49c0…`
(`warmupMainWindow`) and `jsrg_node_54f50e6c…` (`showMainWindow`) show the sequence: await a
window warmup when the document is hidden, wait two animation frames, then show the window
without focus.
Locator: `show-main-window-for-quick-ai-KgBarHIL.js@36`.

Record: `ev_abdd2d16…`; nodes `jsrg_node_283f49c0…`, `jsrg_node_54f50e6c…`.

**R8 [SO]. Promotion to AI Chat is a one-shot cross-window handoff.** The helper writes a
payload under a key prefixed `handoff-` and/or a URL search parameter; `consume()` deletes the
parameter, removes the stored key and returns the value once; `subscribe()` handles the
storage event.
Locator: `window-handoff-fMu7u2Zy.js@363`.
**Unknown:** what the payload contains. The manual claims history, model and attachments
travel; nothing in this pass established that.

Record: none (module outside all four selections).

**R9 [RS + SO]. Root Search exposes four configurable AI slots.** The slot defaults are the
Quick AI command, the AI Chat command, a Google search command, and none; each slot can be
reassigned to any command by id. The chosen slot renders as "Ask in Launcher" and its action
receives the typed text as `fallbackText`.
Locators: `quick-ai-autocomplete-action-options-BFAlj-e4.js@3130` (Google default);
`main-window-DnJ2PGxd.js@1292851` ("Ask in Launcher").

Record: `ev_abdd2d16…` (autocomplete module); main-window has no record.

**R10 [RS]. The start-new-chat clock has explicit options.** Durations are 5, 10, 15, 30 min,
1 h, plus `always` and `never`; the decision uses the newest of `hiddenAt` and
`lastSeenOpenAt` and returns false when neither exists. The AI Chat window services import the
same logic to decide whether opening the chat resumes the last session or starts a new one
(`reopenSessionIdOverride` short-circuits it).
Locators: `quick-ai-start-new-chat.logic-CpYNYQCt.js@315`;
`ai-chat-window-services-DfLJ3crG.js` (import and consumer).

Records: `ev_abdd2d16…` (logic module), `ev_60b5a395…` (consumer module).

### 4.3 Selected text: capture, transform, write-back, permissions

**R11 [SG]. Selection capture is a separate IPC call with a soft failure mode; screen capture
is permission-gated before it runs.** Property-slot `jsrg_node_15e448da…` (`checkPermission`)
and node `jsrg_node_141a5ea1…` (`hideMainWindow`). Selected text returns `undefined` after a
debug log on error. Screen, area and window captures call a permission check first and return
nothing unless it is `granted`. The capture paths in the traced send module (focused window,
screen, selected area, smart context) hide the main window before capturing; the file and
selected-text paths do not.
Locators: `send-to-ai-capture-_skzWBEM.js@436`; `send-to-quick-ai-CkBxSpOW.js@1488`
(`hideMainWindow`), `@1109` ("No text selected"), `@1174`, `@1183` (`source: selection`).
**Inference:** this ordering is what keeps Raycast out of its own screenshot. Not observed.

Record: `ev_abdd2d16…`; nodes `jsrg_node_15e448da…`, `jsrg_node_141a5ea1…`.

**R12 [SG]. The composer handoff is a merge buffer, not a command queue.** Property-slot
`jsrg_node_51db2178…` (`screenAwarenessContexts`) is one of the accumulated fields, alongside
`filePaths` and `textAttachments`; `take()` returns and clears the set; `replace-text`
bypasses the buffer and goes to the composer with its own `send` flag.
Locator: `composer-action-handoff-CdhmkiMR.js@506`.
**Scope correction:** all seven send functions defined in the traced send module (files,
selected text, focused window, screen, selected area, smart context, captured context) dispatch
through this buffer. Send-to-AI commands defined elsewhere in the product were **not** traced
and may not use it.

Record: `ev_abdd2d16…`; node `jsrg_node_51db2178…`.

**R13 [SO]. Quick Fix escalates its text read.** With "prefer selection" it reads the current
selection; on empty or failure it sends a select-all to the frontmost app and reads the field
text. It shows a pending toast ("Quick fixing...") with an abort controller, then a success or
failure toast.
Locators: `main-window-DnJ2PGxd.js@243796` (`applications.selectAll`), `@710944` (pending
toast).
**Limit:** the "unchanged" value is written to the log line only; no branch was found that
gates behaviour on it. Risk to test: select-all in a live document is a real edit-surface
action, and a cancelled run may leave everything selected.

Record: none (module outside all four selections).

**R14 [SO]. A transform that returns nothing is not pasted.** When the transform returns null
or a blank string, the code logs a skip and shows the success toast without writing.
Locator: `main-window-DnJ2PGxd.js@244581`.
**Correction:** this is an *empty-output* guard. It does **not** compare the result to the
source text, so a rewrite that returns the input unchanged is still pasted.

Record: none (module outside all four selections).

**R15 [SO]. Paste failure degrades to clipboard and says so.** Paste is called with
`shouldCloseWindow:true` and `throwsOnTimeout:true`; on rejection the text is copied instead
and a warning toast says the response was copied because it could not be pasted. Abort is
re-checked after each await.
Locator: `main-window-DnJ2PGxd.js@244854`. Static path only; no forced failure was run.

Record: none (module outside all four selections).

**R16 [SO]. Paste is a multi-representation clipboard write.** The clipboard IPC accepts
`items[]` of `representations[]` (content type + mime type) as well as a plain `text` field,
plus `overridePasteboard`, `waitForPaste`, `throwsOnTimeout`, `sourceEntryId` and
`skipStateNotification`. Formatted pastes pass representations; plain pastes pass text.
Locator: `main-window-DnJ2PGxd.js` (multiple call sites; no count is claimed here because the
call sites were not enumerated file-by-file).
**Inference:** "Paste Formatted Response" is possible because the native write publishes
several representations at once; formatting is not reconstructed in the app.

Record: none (module outside all four selections).

**R17 [SO, inference]. Paste is declared as a permissioned action.** The paste and
formatted-paste action definitions declare the Accessibility permission and an alert
("Raycast needs … permission to paste AI responses").
Locator: `main-window-DnJ2PGxd.js@166544`.
**Limit:** that a missing permission actually produces that alert is an **inference from the
declaration**, not an observed runtime path.

Record: none (module outside all four selections).

**R18 [SO]. AI Commands have two output behaviours, and the product description of Replace
Selection is narrow.** Output behaviour is `open-in-raycast` or `replace-selection`. The
in-product description of "Highlight Editing Changes" says it highlights what the command
changed, and — for Replace Selection — "shows highlights only when reopened from history".
Locators: `main-window-DnJ2PGxd.js@205073` (behaviour list), `@218238` (description text).
**What this does not establish:** no preview, diff view or write gate was observed or traced
anywhere in Replace Selection. The manual separately says the feature "marks what changed in
place", which this text does not reconcile. Whether a pre-write diff exists is **unknown** and
is live test T05.

Record: none (module outside all four selections).

### 4.4 AI Chat: follow-ups, queue/steer, history, recovery language

**R19 [SO]. Pending input is first-class state with a delivery mode.** The turn model keeps
`pendingInputs` keyed by command id, each with `sequence`, optional `queuePosition`, `delivery`
(`queue` or `steer`), text, model context, attachments and mention format. Projection events
include `input-admitted`, `input-edited`, `input-steered`, `inputs-reordered`,
`input-abandoned` and `state-changed` with optional `preserveQueuedInputs`.
Locators: `turns-D-5RUxBR.js@5667`, `@8893`; `turn-projection-D22Kzzj1.js@5170`.
**Inference:** more than one message can wait, order is editable, and a queued message can be
converted to a steer. Drain timing and the visible limit are not established.

Record: none (module outside all four selections).

**R20 [SO]. The primary send control is state-dependent.** With text or attachments and a
response streaming the primary action becomes "Queue Message"; with an empty composer it
becomes "Stop Response"; while editing an earlier message it becomes "Edit & Resend"; a `!`
typed into an empty composer enters shell mode.
Locators: `empty-state-default-oQ9UybG0.js@29222` ("Queue Message"), same component for the
label/icon/disabled triple.

Record: none (module outside all four selections).

**R21 [SO, inference]. Degradation has named notice kinds.** Projection emits notice kinds
including `attachment-degraded`, `request-degraded`, `tools-degraded`, `history-elided`
("N older messages omitted — reason"), `compaction`, `provider-compaction`, `retry`,
`retry-attempt`, `recovery`, `continued-from` (reason `change-model` plus model id),
`artifact-authorization`, `image-generation`, `usage` and `plan`.
Locators: `turn-projection-D22Kzzj1.js@12548`, `@11367`.
**Limit:** the *rendering* of these notices was not observed. That the user sees them, rather
than the transcript merely carrying the data, is an inference from the notice objects.

Record: none (module outside all four selections).

**R22 [SO]. Auto routing records its decision.** The `auto-model-route` event carries the
resolved model id and name, the task class and an optional complexity of `easy`, `medium` or
`hard`.
Locator: `turn-projection-D22Kzzj1.js@3529`; schema in `turns-D-5RUxBR.js`.
**Inference:** the decision is inspectable after the fact.

Record: none (module outside all four selections).

### 4.5 Context: files, links, images, screens, budgets

**R23 [SG]. Attachments are a typed union with hard caps.** Types are `file`,
`screen-awareness`, `text`, `document`, `local-path`. Text attachments carry an optional
`source` from `quote | selection | clipboard | note | calendar | browser-tab | process`, an
optional URL, and a preview capped at 1,000 characters. Screen-awareness carries app name,
Raycast app id, window title, browser tab title, selected text **capped at 1,000 characters**,
up to 16 selected file names, an `includedSources` set
(`screenshot | page-text | app-content | focused-control | selection | files`), an optional
screenshot and its size. Command input text is capped at 4,000,000 characters. Capability
records are versioned `qualified-v1` / `qualified-v2`. Vision failure reasons are
`vision-unsupported | unsupported-format | load-failed`.
Locators: `attachments-hQImwAZk.js@3588` (selected-text cap), `@2395` (input cap), `@3893`
(source enum); literals `jsrg_node_40085919…` (1000), `jsrg_node_5b1485d6…` (4000000),
`jsrg_node_1b1280e1…` (`vision-unsupported`).

Record: `ev_abdd2d16…`; literals `jsrg_node_40085919…`, `jsrg_node_5b1485d6…`, `jsrg_node_1b1280e1…`.

**R24 [SO]. Screen-awareness context is budgeted by characters and externalised when it does
not fit.** Inline budget 30,000 characters with a 2,000 floor; per-field budgets selected text
8,000, selected files 2,000, focused element 6,000, browser content 8,000; field caps appName
300, ids and titles 1,000, URLs 2,000, file path 1,000. Content is rendered under a
"[Context from focused app]" marker. When the full JSON exceeds the inline budget, the full
text is produced as `externalizedText` and the inline copy is a binary-search-scaled projection
that fits; selected files are added one at a time until the budget would be exceeded and the
remainder is reported as a count.
Locators: `composer-screen-awareness.logic-DW16s9Kn.js@354`, `@384`, `@399`, `@725`.
**Unknown:** which consumer stores `externalizedText` and whether the model receives a file
path. That step was not traced.

Record: none (module outside all four selections).

**R25 [SO]. Attachment admissibility is checked before upload.** A file is accepted when its
extension is in a fixed set (png, jpeg, jpg, gif, webp, svg, pdf, docx), or its mime type is in
the matching set, or the backend reports it as text, or an online-only iCloud file is probed
for readability. Anything else is rejected by the caller.
Locator: `file-attachment-Bp3qkNDN.js@907`.

Record: none (module outside all four selections).

**R26 [SO]. The full-chat attach menu and Quick AI's attach set differ in scope.** The AI Chat
composer menu offers custom and built-in agents, schedule ranges (today … next month), files
and folders, screen captures (entire screen, selected area, focused window, element), browser
tabs (active/all), selected text, notes, clipboard and link/text attachments. Quick AI's entry
set is narrower: focused window, selected text, screen area or whole screen, plus smart
context.
Locators: `chat-composer-add-menu-DgxDy8kf.js@3075`; the Quick AI subset is in
`send-to-quick-ai-CkBxSpOW.js` exports (RS, module sealed by `ev_abdd2d16…`).

Record: none (module outside all four selections).

**R27 [SO]. Draft state lives outside the composer component.** The composer module keeps
a per-surface store named `ai.surface.draftShell` (alongside selected session, optimistic
input and peeked run), so a draft is not owned by the mounted view. Separately, main-window
has a generic draft-adapter pattern (`getSummary`, `getValues`, `isDirty`, `restoreDraft`,
existing draft id) used by create forms such as AI Command create and calendar-event create.
Locators: `composer-pending-config-DhNfAWgD.js@696` (store keys);
`main-window-DnJ2PGxd.js@184217` (`restoreDraft`).
**Unknown:** whether the `/ai/quick-ai` route registers its own draft adapter; the observed
route entry uses an `onLeave` handler that was not resolved.

Record: none for source coverage. Both modules are outside the four caller-selected sets; inventory presence does not satisfy the RS definition.

### 4.6 Named prompt inputs (placeholder grammar)

**R28–R30 [SO / blocked].** Source reads of `compose-ai-command-prompt-CEWaleWr.js`
(SHA-256 `123f99d5…`, 41,443 bytes); the REA analysis of this file produced inventory identity
and no accepted semantic record (§2).

Record: `ev_d195e061…` covers the inventory entry only, not the contents.

**R28. Arguments are positional, optionally named, with a default and optional choice list;
three distinct arguments maximum.** A fourth distinct argument fails with "Only 3 different
Arguments are allowed" (`@5943`). In the AI Chat consumer an argument without a supplied value
fails parsing ("Argument <name> doesn't have a value", `@8466`); other consumers defer it to a
form field.

**R29. Placeholder availability is per consumer and refusals are explicit.** Selected Text,
Date, UUID and Focused Browser Tab each have an "isn't available in this context" branch
(`@7081`); AI Command and AI Chat consumers reject Date. Recursive references are bounded with
explicit errors for self-reference, circular command reference, circular snippet reference,
multiple matches by title, and unknown placeholders/options/modifiers. A referenced AI Command
must not itself contain dynamic placeholders; only one Cursor placeholder is allowed and it
cannot be used as or with a fallback.

**R30. Composition-time validation precedes send.** The module returns an `invalid-command`
error for an empty submission, and the AI Command form rejects unsupported per-consumer
placeholders at parse time.
**Inference (not observed):** an invalid template therefore fails before any network call.

### 4.7 Keyboard and focus

**R31 [SG]. One shortcut table defines the product, with platform-mapped modifiers.** Primary
⌘ (⌃ on Windows), secondary ⌘⇧, tertiary ⌘⌥, quaternary ⌥⇧, quinary ⌘⌥⇧. Relevant bindings:
⌘J send to AI Chat, ⌘⇧A attach, ⌘⌥⇧A attach to AI Chat, ⌘⇧M change model, ⌘⇧Y creativity,
⌘⇧U reasoning effort, ⌃M dictation, ⌘⇧S or ⌘B chat history, ⌘⇧B branch, ⌘⌥A archive, ⌘⇧P pin,
⌘1–⌘0 jump, ⌘⇧Esc decline all pending tools, ⌘⌥E collapse a question, ⌘R regenerate, ⌘N new,
⌘[ / ⌘] back/forward, ⌘⌥↑/↓ move, ⌃X clear.
Evidence: `ev_94b19218…`; node `jsrg_node_31e2f9eb…` (`sendToAiChat`);
locator `shortcuts-CslcL67B.js` (whole file, 3,946 bytes).

Record: `ev_94b19218…`; node `jsrg_node_31e2f9eb…`.

**R32 [SG]. Key handling is a single-winner dispatch, and Escape-to-close is a setting.**
Nodes `jsrg_node_458bfcb3…` (`stopImmediatePropagation`) and `jsrg_node_b8ee3357…`
(`escapeKeyClosesWindow`, default true, read at call time). Handlers register on one custom
document event; a handler that returns `handled` stops immediate propagation.
Node columns (not byte offsets): `key-down-handler-83o4rabr.js`, column243; `escape-key-closes-window-BqPjb7ny.js`, column63. The construct tokens start at bytes553 and401 respectively.

Record: `ev_94b19218…`; nodes `jsrg_node_458bfcb3…`, `jsrg_node_b8ee3357…`.

**R33 [SO]. IME composition is guarded before shortcut matching.** The composer key handler
returns no action while `isComposing` is true and routes arrow/enter keys to the suggestion
menu when it is visible.
Locators: `empty-state-default-oQ9UybG0.js@29380` (`isComposing`), `@29222`.

Record: none (module outside all four selections).

### 4.8 Model and reasoning control

**R34 [SG]. Reasoning effort is a model-declared capability, not a free choice.** Nodes
`jsrg_node_291799aa…` and `jsrg_node_c984a5d3…` read `abilities.reasoning_effort`. The options
list is built from the declared support, options and default; the chosen effort is clamped to
the declared options and otherwise falls back to the declared default; labels exist for auto,
none, minimal, low, medium, high and extra high; the last-resort default is `medium`.
Locator: `reasoning-effort-options-CLMiRWLu.js@718`; evidence `ev_c844f073…`.

Record: `ev_c844f073…`; nodes `jsrg_node_291799aa…`, `jsrg_node_c984a5d3…`.

**R35 [RS]. The model picker is sectioned, recents-first, and hides the auto sentinels from
Quick AI.** Sentinels `automatic`, `raycast-auto`, `raycast-auto-v2`, `raycast-fastest`,
`raycast-smartest` are treated specially; `raycast-auto` never appears as a normal row; in the
Quick AI source the fastest/smartest sentinels are also filtered; up to three recents are shown
first; sections sort organisation → standard → local. Locked models stay visible with a plan
badge and selecting one routes to the plan path; unavailable local subscriptions route to
setup.
Locators: `runtime-model-submenu-BVeaK-cU.js@4092`; `runtime-model-ordering-1urhCMHD.js`
(sentinel set); evidence `ev_c844f073…`.

Record: `ev_c844f073…` (modules sealed; no node for these literals).

**R36 [SO]. Optimistic input is cleared by an event or by a 10 s timer.** The composer keeps
an optimistic input per session and key; a matching `message-sent` with `accepted:true` clears
it, and a 10 s timer clears it otherwise.
Locator: `composer-pending-config-DhNfAWgD.js@696` (`d=1e4`).

Record: none for source coverage. The module occurs in inventory only, not among the caller-selected sources; this is a direct source read.

## 5. Candidate mechanisms to test (not established gaps)

These are mechanisms, each with the failure mode it addresses. **None is a demonstrated Quick
Launch gap.** Two corrections against the first draft: the transform path in Raycast does not
compare result to source (only empty output is skipped), and Quick Launch already implements a
formatted-paste action, so item 3 is a comparison question, not a missing feature.

1. **Empty-output guard on transform write-back** (R14). Raycast skips a null/blank result; it
   does not skip an unchanged result. Test whether either behaviour matters on echo-prone
   prompts before copying the guard.
2. **Paste failure → clipboard → explicit notice** (R15). One bounded attempt, then a copy and
   a named warning. Measurable by forcing a paste timeout.
3. **Multi-representation clipboard write** (R16). Both products can publish rich
   representations; the open question is which representations each receiving app keeps.
4. **Character-budgeted context projection with externalisation** (R24). A per-field budget,
   a total budget, then an offload plus an inline head. The current Quick Launch map records no
   served-window discovery and no overflow retry; this is a policy to measure, not a proven fix.
5. **Pending-input state with delivery mode** (R19, R20). Queue position, steer, reorder,
   preserve. Quick Launch holds one queued follow-up deliberately; the test is user-visible
   harm, not feature count.
6. **Named degradation notices** (R21). Say which part degraded, when it degrades.
7. **One-shot window handoff** (R8). Promotion that cannot double-apply; test by promoting
   twice.
8. **Warm + two frames + show** (R7) and **serialised init** (R6). Entry-latency policy;
   measurable as entry-to-first-frame and entry-to-first-token.
9. **Declared-capability effort control** (R34). Menu built from model-declared options.
10. **Single-winner key dispatch with an IME guard** (R32, R33). Relevant because Chinese and
    Japanese input are in product scope.
11. **Admissibility probe for attachments** (R25). Allow-list, then a readability probe, then
    accept or refuse with a reason.

## 6. Behavioural questions for live tests

Each question names a measurement and what would falsify the current reading. None can be
settled from static evidence.

**Admission and dismissal**
1. Failing provider, Quick AI: after the window appears, how long until rejection, is the typed
   text restored, is the window usable? Falsifies R2/R3 if text is lost or the window closes.
2. Three launches in under two seconds: does exactly one surface survive, and is any earlier
   text visible in the survivor? Tests R4.
3. Root Search with text, then Tab: does it submit immediately? Repeat with an empty query.
   Tests the documented Tab behaviour against R9.

**Selected text and write-back**
4. Quick Fix on a 2,000-character selection in a rich editor: does select-all visibly fire in
   the target app, and what remains selected after a cancelled run? Tests R13.
5. Force a provider failure on Quick Fix and on an AI Command with Replace Selection: does the
   original text survive byte-for-byte? Tests R14/R15.
6. Paste Formatted Response into Word, Outlook and a plain field: what formatting survives, is
   the plain-text fallback clean? Tests R16 and compares with Quick Launch's existing action.
7. Replace Selection with Highlight Editing Changes on: is any diff visible before the write,
   or only when reopened from history? This is T05 and it is the only way to settle R18.

**Follow-ups and promotion**
8. While streaming, send four messages alternating ⌘↵ and ↵: how many queue, in what order, can
   they be reordered, does one become a steer? Falsifies R19.
9. Press ⌘J twice quickly: one AI Chat window with one copy of the history? Tests R8.
10. Close AI Chat with queued messages pending, reopen: do they survive? Tests
    `preserveQueuedInputs`.

**Context**
11. Send one 500 KB PDF, one 50 MB video, a 3,000-character selection and a 4,000-character
    selection: which are accepted, and what reason is shown for each refusal? Tests R23/R25.
12. Screen Awareness on a window with a long document: does the model receive a truncated
    inline copy plus a path, and does the answer cite it? Tests R24.
13. With Screen Recording denied, run "Send Focused Window to AI": silence, a prompt, or an
    error? Tests the quiet-failure reading in R11.

**Model and timing**
14. Same prompt, same model, ten times, cold and warm: entry-to-first-token for direct-hotkey
    entry versus launcher entry. The only way R6/R7 matter.
15. Change effort on a model that declares only `low` and `high`: does the menu offer only
    those, and what is default? Tests R34.
16. Ten Auto requests, easy and hard: is the chosen model visible afterwards, does it vary?
    Tests R22.

**Keyboard and IME**
17. With a Chinese IME active, type a shortcut sequence mid-composition: does any shortcut
    fire? Tests R33.
18. In the chat composer, with an empty composer, press **↑** (not ↓): is there prompt-history
    walk-back, and does Esc restore the draft? The manual claims it; no shipped module for it
    was traced, so it is **unknown**.

## 7. Limits and unknowns

- **Static only.** No Raycast process was launched; no request, paste, focus change or render
  was observed. "Implemented" never means "works".
- **Three evidence classes, unevenly distributed.** Of the 36 claims: 9 are SG only
  (R1, R4, R7, R11, R12, R23, R31, R32, R34), 3 are SG + RS (R2, R3, R6), 3 are RS only
  (R5, R10, R35), 1 mixes RS with a source-only module (R9), 17 are SO only, and 3 are
  SO with a blocked analysis (R28–R30). So: 12 claims have at least one sealed semantic node,
  3 rest on a direct read of bytes sealed by a selected module record (no node), 1 mixes a selected module
  with a module no source-analysis record covers, and 20 rest on direct source reads without selected-source coverage. §3 is the
  authority; this bullet is a summary.
- **Native implementation unresolved** for selection capture, screen capture and paste
  delivery: the binary is stripped and no Swift function was attributed.
- **Blocked:** the composition module has inventory identity only (`ev_d195e061…`, 0 analysed
  files, 0 relations). Prompt-grammar claims rest on direct source reads.
- **Minified identities.** Filenames carry content hashes and change between versions;
  re-locate by Appendix A, not by filename.
- **No IPC channel names.** REA reported zero literal channels for these selections because
  the transport is a proxy; message shapes were read from call sites.
- **Not established:** the handoff payload; chat-history retention period (only the 60-day
  Notes string was seen); whether `externalizedText` is stored or re-sent; the backend
  speed-boost policy; drain timing for queued inputs; the attachment count limit; how link
  previews are fetched; whether Replace Selection ever shows a pre-write diff.
- **Not measured:** any latency, model quality, visual result or accessibility behaviour.

## 8. Reproduction

```bash
# identity
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Raycast.app/Contents/Info.plist
stat -f%z /Applications/Raycast.app/Contents/MacOS/Raycast
shasum -a 256 /Applications/Raycast.app/Contents/MacOS/Raycast \
  /Applications/Raycast.app/Contents/Frameworks/libraycast_host.dylib

# module identity (authority is Appendix A)
cd /Applications/Raycast.app/Contents/Resources/macos-app_RaycastDesktopApp.bundle/Contents/Resources/frontend
shasum -a 256 quick-ai-entry-*.js quick-ai-services-*.js shortcuts-*.js attachments-*.js

# locator offsets
grep -bo -F 'stillPresented' quick-ai-entry-*.js
grep -bo -F 'transform produced no change; skipping paste' main-window-*.js

# re-run a sealed analysis (writes outside the repo)
ROOT=/Applications/Raycast.app/Contents/Resources/macos-app_RaycastDesktopApp.bundle/Contents/Resources/frontend
npx -y rea-agents@6.7.0 analyze-javascript-application "$ROOT" \
  --source-path=quick-ai-entry-B_WAMKaf.js --source-path=quick-ai-services-fArxFyDT.js --format=json
```

Saved records in the local comparison evidence directory: `js-A.json` (`ev_abdd2d16…`),
`js-B.json` (`ev_60b5a395…`), `js-D.json` (`ev_c844f073…`), `js-E.json` (`ev_94b19218…`),
`macho-main-2.8.2.json` (`ev_d9060ec9…`), `macho-host-2.8.2.json` (`ev_697f0cf6…`),
`js-C.json` (timeout envelope containing partial `ev_d195e061…`),
`composition-analysis-blocked.md`.

## Appendix A. Cited modules: full SHA-256 and byte length

Recomputed from the installed 2.8.2.0 bundle on 2026-10-22. It lists every module cited in the
body plus the rest of the four selected files, for completeness. Hash prefixes elsewhere in
this document are locators only; this table is the reproducible identity.

| Module | Bytes | SHA-256 |
| --- | --- | --- |
| quick-ai-entry-B_WAMKaf.js | 4,232 | `fd3e7c456adc80f452a419cb146e897f94307f52939f8a3c8b782504058209ab` |
| quick-ai-services-fArxFyDT.js | 4,018 | `3b5dda19b4b787b2e803c9d4a3ea70441d4fe0baf4f0a31a3c3778a70d246afe` |
| quick-ai-start-new-chat.logic-CpYNYQCt.js | 712 | `2cd0ff5c89f3e00eb7a27d2fd9564a9a2e39e52a2a71e4112010d948d807fcb3` |
| show-main-window-for-quick-ai-KgBarHIL.js | 592 | `033fdb95f15a95f7c0c70f75090812c690d66f1b7a87f3ebd156884e2698cb30` |
| send-to-quick-ai-CkBxSpOW.js | 2,626 | `39de15fc662972c49ebd0ddb37f4f8412643baeef8c356ed408bcea744534c1d` |
| send-to-ai-capture-_skzWBEM.js | 1,253 | `30392125c073c63e40c15879de8bc9f4f162ee40c348b65e46f0815f1c256adc` |
| composer-action-handoff-CdhmkiMR.js | 1,457 | `dc7b5a623720fb6d266f15061f1e09f534cbf48fe389ec575f9afd2a949cbea2` |
| ai-access-policy-BSHhTSFU.js | 826 | `87eb4ff45d596574274d469aadcf613e41838ee91d28d94040fbbd8d0eb71b10` |
| quick-ai-footer-UMTbxQX2.js | 2,184 | `55a1d97d0472fd3edc1fbbf61ac00917365db9a9a36d07439acf473f808284af` |
| quick-ai-autocomplete-action-options-BFAlj-e4.js | 4,114 | `3d337c2cea90cf53bd4d9b2cc56afee1248adf1dfaac17f1613bbdcf6fb6eefb` |
| attachments-hQImwAZk.js | 5,218 | `6d2cad1e6a8c010d6119f0d00f6acec3242f19acb6da8e5f52ab5962a6a6b030` |
| composer-pending-config-DhNfAWgD.js | 10,224 | `57c31ca51519177604c24c39ce0a270e522ccb5553d139a2bdc99f0df0f74257` |
| ai-chat-window-services-DfLJ3crG.js | 6,356 | `36df9feddbaf3540f36525f661bb262fecef3a57062e3fbabb2ce06b2e94c195` |
| ai-chat-handoff-BjPTMtVf.js | 489 | `7a61c6ee260b067ccbdf73461a7f842edc56703b64b6b280a8a552d883d3fc2e` |
| runtime-model-submenu-BVeaK-cU.js | 7,219 | `b1a4a36a354f3880815bfad73ee7044e49076beb7300f3ffd7a6d19c62f6734e` |
| reasoning-effort-options-CLMiRWLu.js | 1,095 | `c3a30bf5e5e9d02021cab28d2eb4aab1a283d96253ec896726e128fcc6e50bee` |
| runtime-model-ordering-1urhCMHD.js | 1,061 | `e25e44b46ac0308d71ded3397b79ac580103eb0150fb1768e8202c2f50e5d8e1` |
| shortcuts-CslcL67B.js | 3,946 | `540a8fd4cfdbb41746cab5e6148865d7dcae77bd8811810eff62e1e084d8952b` |
| key-down-handler-83o4rabr.js | 835 | `7be2249f2ada71be783ddd123567ecf00c8a48aaf12a50b5edd8d2d76277645f` |
| escape-key-closes-window-BqPjb7ny.js | 549 | `dd7b8d2a452871ecb4603f5c848be827e747be0d0076b6fb29c5e70506d64404` |
| main-window-DnJ2PGxd.js | 1,663,733 | `114360f2542dc074846c9a36f8854fc570bce94d2e6751e37e6cf1c2bb2d3f1e` |
| compose-ai-command-prompt-CEWaleWr.js | 41,443 | `123f99d5dc0363b1fa717cc54c3fdad4326bcf81ce3fa043765a121db22b02ee` |
| window-handoff-fMu7u2Zy.js | 1,175 | `8226f8addfb15ba3371c0453bd382d81ab6d18fb7fc3c1880dba8e29a6179167` |
| turns-D-5RUxBR.js | 16,090 | `bfb9ce85e1a8c3f585e070b44a737c1501944adf301b62ecead364c927e26ea7` |
| turn-projection-D22Kzzj1.js | 16,919 | `2d78a4a2fd47a0b06eaba2a2fadc9dff704ee795e62989990d0f05e2fd4c67b7` |
| chat-composer-add-menu-DgxDy8kf.js | 16,361 | `549f49c09d380758e6b5e38500db386328554ecfc0dfa258ad9c5340a40440b2` |
| empty-state-default-oQ9UybG0.js | 306,433 | `606d4b20194396f4404d2bf43be9d5606964ce664c3ec7435c2152ea30188c18` |
| file-attachment-Bp3qkNDN.js | 1,819 | `7fc31bf530afb94f981f6e6745fdbf9da8b7de9bf79b3411e4751ad7c333b62b` |
| composer-screen-awareness.logic-DW16s9Kn.js | 3,906 | `ce63447d231ee4e603048a6aeaf48987aca2f5918715ae9c9867986464f7f0b1` |
| pending-interaction-composer-CTy1rj3x.js | 19,178 | `864c9fbf96c238b9002f7978b236aa61cc5bf0c9b866e872a8c17f9d914079cc` |
| ai-chat-window-l7ASu73j.js | 13,082 | `1f05ab00c2d3ea8be810f9b8d75770cedafdf13f92ae053fc654fbad07abf870` |
| ai-window-context-goRezJgI.js | 494 | `7a66b73116ebcf58debf3f0617db9ea7c6e37a335a7ff54399ea82872116cc59` |
| chat-layout-Bf5ly9dF.js | 7,123 | `fee886ed8b6557d443cdeed75009d2f9052150abfec76a361b11d08197dc5804` |
| use-ai-chat-router-DiaTorT5.js | 22,001 | `074b6978bfcea8796eb93438d01acbb2b4a94618f20bfd380dae0b6be2553223` |
| App executable (Raycast) | 16,208,512 | `9d823200b6fc4803c9a669d295035654598b7c0655434bc86f27f71493af3076` |
| Host dylib (libraycast_host.dylib) | 5,496,496 | `94af755b2402cf4087288f7834887c13628f8eaa171080f281eb88954b0e5d3e` |

## Appendix B. Full semantic-node IDs

Abbreviated `jsrg_node_xxxxxxxx…` in the body are locators. This table is the identity. Each
ID was resolved uniquely in the saved record named in §3; the construct column is what that
node carries in the graph.

| Prefix | Full node ID | Kind | Module | Construct |
| --- | --- | --- | --- | --- |
| `13ab99ce` | `jsrg_node_13ab99ceb89cb37ca24687486584d31ff5045cb22f17fc77ce59129659fcdfc5` | expression | quick-ai-entry-B_WAMKaf.js | stillPresented (R3) |
| `141a5ea1` | `jsrg_node_141a5ea116e9981f7efe6b95f19c6a896153e836e3fd442c54b9b02ce666f23b` | expression | send-to-quick-ai-CkBxSpOW.js | `ipc.host.raycast.hideMainWindow` (R11) |
| `15e448da` | `jsrg_node_15e448dae410534cb2c3d6e598502f08f3d5b2a653b04c20594c6301bd298617` | property-slot | send-to-ai-capture-_skzWBEM.js | checkPermission (R11) |
| `1b1280e1` | `jsrg_node_1b1280e15df38c8665aeac2ff3d0e23a6399dfd138a9e697a5c1c0380cb87415` | literal | attachments-hQImwAZk.js | vision-unsupported literal (R23) |
| `283f49c0` | `jsrg_node_283f49c0a3614fe176a4348b469589a20798584529883bf6bdf2d5d374154c00` | expression | show-main-window-for-quick-ai-KgBarHIL.js | warmupMainWindow (R7) |
| `291799aa` | `jsrg_node_291799aa34a06d449fc3d94c70cd9bf80714c467c6acd0cf79e4b2104ec03ba9` | property-slot | reasoning-effort-options-CLMiRWLu.js | abilities.reasoning_effort property-slot (R34) |
| `31e2f9eb` | `jsrg_node_31e2f9eb592d980b3fd3fadc5655e47ca567a1a837081daa9670e8919093b1a2` | property-slot | shortcuts-CslcL67B.js | sendToAiChat (R31) |
| `3dec9564` | `jsrg_node_3dec9564a3da85b77709de8be9933e3f8866834c93fd24338a724fc64f10a201` | property-slot | quick-ai-entry-B_WAMKaf.js | cancelPendingLaunch (R4) |
| `40085919` | `jsrg_node_40085919c0ca07bba9156318cd6dafa8b3112fdc2e75a3db57791d9684e39f72` | literal | attachments-hQImwAZk.js | 1000 literal (R23) |
| `458bfcb3` | `jsrg_node_458bfcb3dc32df32bbdd484657821166c263ead97e73b58fd0a4aa79c48ae128` | expression | key-down-handler-83o4rabr.js | stopImmediatePropagation (R32) |
| `51db2178` | `jsrg_node_51db2178129802aede5c28921284d376e7e6724e1f74e60357eafc3651528fe0` | property-slot | composer-action-handoff-CdhmkiMR.js | screenAwarenessContexts (R12) |
| `54f50e6c` | `jsrg_node_54f50e6cf905e495cda6b5416b4fd46c18c5a744ec0b841a9104a11eadcc9463` | expression | quick-ai-entry-B_WAMKaf.js | showMainWindow (R7) |
| `59fb04cc` | `jsrg_node_59fb04cce35210a1892ad2d48a60ff3b752a2f6d62ea4df642344c0c33a664a0` | expression | quick-ai-entry-B_WAMKaf.js | `admitted.then` (R2) |
| `5b1485d6` | `jsrg_node_5b1485d69832aa797d5f5a5ccc2816e07c1dc421c6bb2903a7bd0b08114e8b3b` | literal | attachments-hQImwAZk.js | 4000000 literal (R23) |
| `8f2b3b39` | `jsrg_node_8f2b3b39cf0dc6cc3ac856087fce9c8984a5e04101fea9e8213ee1b9ddcebbfd` | promise | quick-ai-services-fArxFyDT.js | aggregated await / Promise.all (R6) |
| `b8ee3357` | `jsrg_node_b8ee33571b8639754ea7f7ae3ea074cb7c55dbbfb1dd4b840a99461c51ed525e` | expression | escape-key-closes-window-BqPjb7ny.js | escapeKeyClosesWindow (R32) |
| `c984a5d3` | `jsrg_node_c984a5d3738576effb06800507db93bd09155a4f315b34cf8e911c78eb4380a8` | expression | reasoning-effort-options-CLMiRWLu.js | abilities.reasoning_effort read (R34) |
