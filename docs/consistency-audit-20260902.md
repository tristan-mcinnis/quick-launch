# Quick Launch consistency audit (2026-09-02)

Read-only audit by four parallel agents: keyboard handling, view-model modes, persistence/services, view layer and scope. Question asked: where does the codebase have "one set of rules for this and another for that"?

Short verdict: the codebase is in good shape at the service level (protocols, tests, no shell interpolation except one site, no telemetry). The problems are all in the middle layer: the overlay has no single notion of "what mode am I in", so every key, every reset, and every input-classifier re-derives it from a different subset of flags. The Escape complaint is a direct symptom.

## 1. The Escape bug, and why it exists

- `handleEscapeKey` (`QuickViewModel.swift:4207`) never touches `input`. It pops item pane, palette, stream, then dismisses. Hidden overlay then keeps the text for 10 s (`AppDelegate.swift:621-660`, `reopenRetentionSeconds`). So Escape looks like "close but remember", and clearing means holding Backspace.
- The translator panel already does the right rule (`AppDelegate.swift:895-903`): picker, then clear text, then close. Two panels, two Escape rules.
- Backspace-on-empty (`:4182`) walks a *different* layer stack (attachment > answer > inputMode > catalog) from Escape (pane > palette > stream > dismiss). Two "back" keys, two stacks. Empty Backspace in answer state starts a new conversation, which is destructive for a key that elsewhere means "go up one level".
- One-line fix: in `handleEscapeKey`, before the dismiss branch, add `if !input.isEmpty || hasPendingAttachment { input = ""; removePendingImage(); return }`.
- Real fix: one ordered layer stack (attachment > typed text > item pane > palette > answer > input mode > catalog > root) that both Escape and empty-Backspace pop.

## 2. Keyboard handling: six layers, no table

Keys are handled in: `KeyablePanel.sendEvent` (`AppDelegate.swift:29-47`, raw Esc/Backspace), `performKeyEquivalent` (`:49-86`), AppDelegate closures (`:507-532`), SwiftUI `onKeyPress` in `OverlayView.swift` (`:40-74`, `:303`, `:1097`, `:1391`), view-model policy functions (`:1636`, `:1798`, `:4182`, `:4207`, `:4234`, `:4250`), and three separate worlds (Translator, Type to Click CGEvent tap, HotkeyRecorder).

Findings, ranked:

1. Escape never clears text (above).
2. Empty Backspace and Escape disagree (above).
3. Dead code from double handling: `onKeyPress(.escape)` at `OverlayView.swift:303` and `:1394` never fire because `sendEvent` eats Escape first. `closeActionPalette` at `:1394` is unreachable. `onKeyPress(.delete)` at `:72` duplicates `sendEvent :38`.
4. Shift+Return is silently swallowed when no translation direction is set (`AppDelegate.swift:73-78`).
5. Bare Return in answer state with empty input pastes the answer back (`QuickViewModel.swift:1664`). Everywhere else Return means "run selected". Paste-back belongs on Cmd+Return.
6. Tab has three meanings behind a six-term boolean guard (`:1798-1806`).
7. Magic keyCodes (53, 51, 36, 76, 48, 125, 126) as literals in 14 places across 6 files. No `VirtualKey` enum.
8. Three different "intercept before the text field" mechanisms: sendEvent, performKeyEquivalent + cancelOperation, CGEvent tap + synthetic events.

Structural fix: one `OverlayKeyDispatcher` on the view model, `handle(key: VirtualKey, mods:) -> Bool`, switch on `(key, topLayer)`. `sendEvent` forwards every keyDown; false falls to super. About 150 lines moved, not rewritten. Existing tests become table tests.

## 3. Mode state: 7 Bools + 5 optionals, no enum

`QuickViewModel.swift:10-70`: `isStreaming`, `output` (a String used as a flag), `isActionPalettePresented`, `isApplicationActionPanePresented`, `isCatalogActionPanePresented`, `activeItemActionForm`, `catalogScope`, `pendingQuickLinkID`, `isConversationHistoryPresented`, `pendingImages`, `inputMode`, `activeVaultSearchMode`, `currentConversation`. Derived: `isAnswerActive` (`:1190`), `isFollowUp` (`:1609`), `isItemActionPanePresented` (`:4001`).

Consequences:

- Representable impossible states: both panes open at once; `catalogScope` and `inputMode` both set (AppDelegate `:1020-1022` sets catalog directly without clearing inputMode); vault search mode alive while inputMode is askAI; history presented with no conversation.
- Answer mode is inferred from non-empty `output`. A local math result therefore enters the same "AI thread" mode as a streamed answer: Return pastes back, launcher rows hide.
- Guard duplication: `isAnswerActive` checked 9x, `catalogScope` 9x, `inputMode` 5x, `pendingQuickLinkID` 5x, each in different subsets.
- Type to Click is a parallel state machine owned by AppDelegate with no view-model representation.

Fix: `enum OverlaySurface { root, catalog(scope), quickLinkInput(id), inputMode(InputMode), attachment, answer(Thread) }` plus `enum Layer { none, itemPane(form?), palette }`. Make the Bools computed views over it.

## 4. Three input classifiers that disagree

1. Live ranking `rankLauncherMatches` (`:1194-1290`): answer > URL > alias-boosted Ask AI > items.
2. Return `submitResolvingFuzzyAlias` (`:1636-1683`): image > input mode > exact command alias > vault follow-up > empty pasteBack > quick link > selected row > fuzzy alias > submit.
3. `submit()` (`:4871-5178`, 308 lines): alias > `{selection}` > math > conversion > facts > web search > page read > provider.

Where they disagree:

- Math beats everything in ranking, but a selected launcher row beats math on Return, and math beats alias inside `submit()`. Outcome depends on which row `applicationSelectionIndex` points at.
- Command aliases got a special early slot (commit 57cecba) because answer mode swallowed them. Prompt aliases did not, and still lose to vault follow-up. Same class of input, two precedence rules.
- Typed URL: ranking uses `TypedURLDetector` (open Quick Link); `submit()` uses `PromptURLScanner` (read page for model). Same text, two outcomes depending on row selection.
- `SavedPromptResolver.resolveAction` runs three times per Return (`:1647`, `:1672`, `:4883`).
- `.askAI` input mode nulls itself before calling `submit()` (`:1822`).

Fix: one `InputClassifier` returning an ordered `Intent` (commandAlias, promptAlias, localAnswer, typedURL, launcherRow, askAI, vaultFollowUp). Ranking and Return both consume it. `submit()` takes an Intent, not text.

## 5. Eleven reset functions, each forgetting something

| Function | Line | Forgets |
|---|---|---|
| `cancel()` | 5488 | streamingStatus, lastQuestion, errorMessage |
| `clearTransientDisplay()` | 5578 | inputMode, selection index, pendingContext, activeItemActionForm; does not cancel stream |
| `leaveCatalog()` | 2833 | activeVaultSearchMode, pendingImages, activeItemActionForm |
| `leaveInputMode()` | 1809 | activeVaultSearchMode |
| `startNewConversation()` | 5631 | does not cancel streamTask; pendingImages, catalogScope |
| `clearHistory()` | 5644 | lastQuestion, conversationImages, input |
| `AppDelegate.hideOverlay()` | 621 | writes 6 VM fields from outside |

Fix: one `reset(to: OverlaySurface)` primitive. Low effort, high payoff.

## 6. Bypass paths around the view model

- NotificationCenter as control bus: 32 `.dismissOverlay` posts plus 6 other names, defined in a *view* file (`OverlayView.swift:1659-1672`). Settings views post directly.
- AppDelegate writes VM state directly (`:621-629`, `:1020-1022`, `:660`). `OverlayView.swift:783` and `CatalogPanes.swift:34` also write VM fields.
- 88 direct AppKit calls inside the view model (`NSPasteboard`, `NSWorkspace`, `NSRunningApplication`, `NSScreen`) next to properly injected protocols for clipboard/window/screenshot.
- Fix: inject an `OverlayPresenting` protocol with one AppDelegate implementation; move Notification names out of views.

## 7. Persistence: same job, six ways

| Store | Mechanism |
|---|---|
| QuickSettings, QuickHistoryStore | UserDefaults JSON blob |
| ClipboardHistoryStore, ColorHistoryStore | JSON file, async queue, chmod 0600 (identical copies) |
| LauncherUsageStore, ScreenshotTextIndex, TranslationHistoryStore | JSON file, sync write, no 0600 (translation has it), one lives inside a ViewModel file |
| SQLiteScreenHistoryStore | SQLite actor, schemaVersion 7, migrations |
| Soak/Freeze receipts | JSON, ISO8601 dates, different Application Support API |
| APIKeyStore and CoastFreezeReceipt | two hand-rolled Keychain clients, two service-name conventions |

- `"Library/Application Support/Quick Launch"` hand-built in 7 places. No `AppPaths`.
- Chat history is the only history in UserDefaults.
- Fix: `AppPaths` + one `JSONFileStore<T>` (atomic, 0600, optional version, async). Collapses 6 stores. One Keychain client.

## 8. Services and processes

- 32 protocols; 17 in `Sources/Protocols`, 8 declared inside service files, 13 services concrete-only or static enums. Three coexisting styles (protocol+injected, `@MainActor final class`, stateless enum).
- `QuickViewModel.init` injects 8 services but builds `LauncherUsageStore` (`:236`), `ModelCatalogService` (`:5398`), and the brew updater (`:5732`) inline.
- `QuickServiceError` lives in `OpenAICompatibleService.swift:291`, not with the protocol.
- Process: 13 `Process()` sites. One shell violation: `QuickViewModel.swift:5734` runs `/bin/sh -c "brew upgrade quick-launch"`. Constant string, but the only shell in the tree and against AGENTS.md. `ModelCatalogService:80-83` waits before reading stderr (deadlock risk). Three near-identical ssh builders (`VaultSearchService:111`, `WebPageReader:129`, `SearXNGSearchService:110`).
- `QuickToggleService.readFinderBool` (`:165-180`) runs Process synchronously with no actor hop.
- Errors: 162 `try?`, every JSON store load/save silent on failure. `os.Logger` in exactly 2 files; everything else silent. Fail-silent is the de facto policy.
- Concurrency: 15 actors vs 14 `@MainActor` classes with no rule for which is which.
- Fix: `ProcessRunner.run(executable:arguments:)` on a detached task, `SSHRunner`, `os.Logger` per subsystem wherever `try?` swallows I/O.

## 9. View layer

- Sizing: one formula in `PanelSizing`, but OverlayView re-derives the same numbers by hand (`:342-355`, `:428` hardcodes 42, `:936` and `:1103` repeat header 44/40). About 15 magic numbers held together by comments. Widths live on the view model, not PanelSizing.
- Lists: four hand-copied "ScrollView > LazyVStack > ForEach > Button > selectionFill" panes (`OverlayView.swift:410`, `:1033`, `:1405`; `TranslatorView.swift:170`), each with its own selectedIndex/move/runSelected.
- Focus: six mechanisms (FocusState x6, a counter `inputFocusRequest`, `Task.yield` copied 4x, `NSApp.activate` x5, `makeFirstResponder`, a 50 ms retry loop up to 40 attempts in TypeToClick).
- Styling: `DesignTokens` is good, but 111 hardcoded `.font(.system(size:))` and friends remain; `preferredColorScheme` set in three places; Welcome forces light.
- Settings: consistent binding pattern, but `.save()` called manually 39 times. A `settings.binding(\.x)` helper that saves on set removes all of them.
- Duplicate utilities: 3 fuzzy rankers, 8 private `normalize()` helpers, `openAccessibilitySettings` in two places, 7 inline date formatters.

## 10. Scope drift

| Cluster | Share of 55,660 lines |
|---|---|
| Screen History + Coast (own files) | 32% |
| Screen History inside core files | 3.5% |
| Type to Click | 6% |
| Core overlay | ~39% |
| Everything else (emoji, catalogs, translator, web, vault, clipboard, color, caffeinate, math, tuna) | ~20% |

- Screen History is 36% of the repo. The core overlay is 39%. QuickViewModel has 528 screenHistory refs and a 1,190-line Screen History section (`:1886-3074`). `ItemActionForm.screenHistorySave` forces core `ItemAction`, `PanelSizing`, and OverlayView to know about it. QuickSettings has 11 of ~50 fields for satellites.
- Docs contradict code: README `:243` says Apple inference stays local (removed 2026-08-22). README `:303-309` and AGENTS.md `:57-59` say the app does not observe or record the screen, but `ScreenHistoryCaptureService` (940 lines) and the "Enable owned screen capture" toggle exist. Type to Click (10 of the last 12 commits) is in neither README nor `docs/product-scope.md`. `AgentSessionWatcher` has no doc and no tests.

## Ranked plan

Ordered by payoff over effort. Items 1 to 3 are one focused session each and fix the felt problem.

1. **Escape clears text before closing** (one `if` in `handleEscapeKey`). Ten minutes. Do this today.
2. **One layer stack for Escape and empty Backspace**; delete the dead `onKeyPress` handlers; add `VirtualKey` enum; move paste-back off bare Return. Half a day.
3. **`reset(to:)` primitive** replacing the 11 resetters. Half a day.
4. **`OverlaySurface` enum** replacing the flag soup; Bools become computed. One to two days, tests exist.
5. **`InputClassifier` with one `Intent` order** shared by ranking and Return; split `submit()`. One day.
6. **`OverlayPresenting` protocol** replacing the 32 notification posts and direct AppDelegate writes. Half a day.
7. **`AppPaths` + `JSONFileStore<T>`**, one Keychain client, chat history out of UserDefaults. One day.
8. **`ProcessRunner` + `SSHRunner`**, drop `/bin/sh -c`, fix stderr ordering. Half a day.
9. **Extract `ScreenHistoryController`** out of QuickViewModel and core types. Two days, biggest structural payoff, lowest urgency.
10. **`SelectableListPane`**, `settings.binding(\.x)`, os.Logger policy, docs fixes. Mechanical.

Executed read-only. Nothing changed.
