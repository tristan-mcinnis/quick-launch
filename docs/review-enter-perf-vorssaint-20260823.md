# Review: what Return does, performance bugs, and what to borrow from Vorssaint

Date: 2026-08-23. Source read: `QuickViewModel`, `OverlayView`, `AppDelegate`, services. Numbers below were measured on this Mac with a throwaway test (252 apps, 56 commands, 89 snippets, 48 quick links), then the test was deleted. Nothing in the repo changed.

## 1. What Return does after you type

### The rule in the code

`submitResolvingFuzzyAlias()` ([QuickViewModel.swift:989](../Sources/ViewModels/QuickViewModel.swift:989)) runs this order:

1. Attached image → ask the AI.
2. A mode (Caffeinate Until, Rename) → submit the mode.
3. Answer on screen and nothing typed → paste the answer back.
4. Pending Quick Link → open it.
5. **Any launcher row visible → run the highlighted row** ([:1049](../Sources/ViewModels/QuickViewModel.swift:1049)). Row 0 unless you pressed an arrow.
6. Otherwise → `submit()` → saved prompt, local math, system facts, web search, or the AI.

So Return is **not** "ask the AI". Return is "do the highlighted row". The AI only gets the text when the list is empty.

### When is the list empty?

`rootLauncherQuery` ([:176](../Sources/ViewModels/QuickViewModel.swift:176)) hands the text to the launcher when it is 1 to 64 characters, has no newline, and does not start with `/`. A row appears when the letters you typed occur **in order** inside any app name, command title, snippet title, quick link title, or catalog name ([FuzzyMatcher.swift:15](../Sources/Services/FuzzyMatcher.swift:15), plain subsequence match). Spaces must match too, which is why most multi-word prompts fall through.

### Measured on this Mac

| Typed | Return does | Footer says |
|---|---|---|
| `hi` | opens Hidden Bar | Open |
| `ok` | opens Books | Open |
| `yes` | opens System Settings | Open |
| `what` | opens WeChat | Open |
| `shorten` | opens Shortcuts Events | Open |
| `weather` | opens Weather | Open |
| `summarize this`, `fix grammar`, `translate hello`, `write a haiku`, `explain this`, `rewrite`, `polish`, `expand`, `what is the capital of france`, `Draft a reply saying…` (65+ chars) | asks the AI | Ask |

So in practice: **one word = launcher, two or more words = AI**, with exceptions in both directions that depend on luck (which apps and snippet titles you happen to have). The footer is correct but nobody reads the footer mid-flow, and the ranking list does not show an "Ask AI" row, so the screen gives no cue that Return will go to the model.

### Why this matters

- `hi`, `ok`, `yes`, `what` launching apps is wrong for an "AI action overlay".
- A two-word prompt can be hijacked by any snippet title that contains its letters in order. None of the 18 prompts tested hit one today, but that is luck, not design. Add one snippet called "What is the..." and `what is` opens it.
- Nothing is tested. There is no test that says what Return does for a question.

### Recommendation: make "Ask AI" a row and a rule

Keep "Return = highlighted row". Change what gets highlighted:

1. **Add an `Ask AI: <text>` result** to the root list whenever the text is not empty, not a `/alias`, and not pure math. It is an Item like any other, so it gets the footer, ⌘K, arrows for free (primitives doc, section 7).
2. **Rank it first when the text reads like a prompt**: two or more words, or ends with `?`, or starts with a verb/interrogative from a short list (`what how why who when write draft explain summarize translate fix rewrite make tell define`). Rank it last (below launcher rows) for a single word.
3. **Weak matches never take Return from a prompt.** A subsequence-only match (no exact, prefix, word-start, alias, pin, or learned mnemonic bonus in `matchScore`) on a query of two or more words stays visible as a row but does not outrank `Ask AI`. A learned mnemonic or exact alias still wins, so `cla` → Claude keeps working and `weather` still opens Weather.
4. One test per line of the table above, in `ApplicationLauncherWorkflowTests`, so the rule cannot drift.

Net effect: `hi` shows Hidden Bar first and "Ask AI: hi" second (arrow down to ask). `what is` shows "Ask AI: what is" first. The footer keeps saying Open or Ask, but now the highlighted row says it too.

## 2. Performance bugs and risks

Ordered by how much they cost you per day. The "Speed contract" in `docs/primitives.md` is met for typing (1.3 ms per keystroke, 1.9 ms with Tuna loaded; the cache-key cost is 3 µs). The problems are elsewhere.

### P1. Streaming re-parses the whole answer on every token

- `output += text` per delta ([QuickViewModel.swift:2706](../Sources/ViewModels/QuickViewModel.swift:2706)).
- Each change re-evaluates `OverlayView.body`, which calls `MarkdownRenderer.render(viewModel.output)` on the **full** string ([OverlayView.swift:245](../Sources/Views/OverlayView.swift:245)): 1.5 ms at 4 k chars, 4.8 ms at 12 k.
- Then `MarkdownTextView.updateNSView` compares the whole attributed string and calls `setAttributedString` (full re-layout) ([MarkdownTextView.swift:37](../Sources/Views/MarkdownTextView.swift:37)).
- Then the panel-size observer fires a Task per delta ([AppDelegate.swift:897](../Sources/App/AppDelegate.swift:897)) and recomputes `launcherMatches`, `conversationTranscriptText`, and `panelHeight`, and resizes the window with `display: true` when a line is added.

Cost is O(answer length) per token, so O(n²) per answer. At DeepSeek speeds (50 to 100 deltas a second) a long answer spends most of the main thread on re-rendering, which is the "typing feels laggy while it streams" symptom and it also delays the keystrokes of a follow-up.

Fix: coalesce deltas. Append to a buffer and publish `output` at most every 33 ms (one `Task` that sleeps, or a `CADisplayLink`). Memoize `MarkdownRenderer.render` on the string. That alone cuts the work 3 to 10×. A later step: append-only text-storage edits instead of `setAttributedString`.

### P2. Opening the panel decodes the clipboard image every time

`showOverlay` → `captureImageFromClipboard()` ([QuickViewModel.swift:3083](../Sources/ViewModels/QuickViewModel.swift:3083)) → `ClipboardImageReader.attachment()`. If the clipboard holds a TIFF (any ⌘C of an image, any screenshot copied) it decodes the TIFF, re-encodes to PNG, and decodes the PNG again ([ClipboardImageReader.swift:14](../Sources/Services/ClipboardImageReader.swift:14)), synchronously, on the hotkey path. Measured 28 ms for a 2560×1600 image; a 5K screenshot is several times that. This repeats on **every** open while that image stays on the clipboard, even after you removed the attachment.

Fix: remember `NSPasteboard.general.changeCount` with the decoded attachment and skip the decode when it has not changed. One integer compare instead of 30 to 100 ms.

### P3. App icons are fetched uncached inside the row view

`LauncherResultRow.icon` calls `NSWorkspace.shared.icon(forFile:)` every render ([OverlayView.swift:527](../Sources/Views/OverlayView.swift:527), also `:647`). Cold cost measured 5 ms per icon (44 ms for nine rows); warm 0.07 ms. Every new app that scrolls into the list as you type costs 5 ms on the main thread the first time, so the first few keystrokes of a session stutter.

Fix: an `[String: NSImage]` cache keyed by path, warmed in a background task at launch for the catalog (252 icons ≈ 1.3 s off the main thread, once).

### P4. Clipboard History writes the whole file on every copy

`record` → `save()` ([ClipboardHistoryStore.swift:39](../Sources/Services/ClipboardHistoryStore.swift:39), [:126](../Sources/Services/ClipboardHistoryStore.swift:126)) JSON-encodes every entry (up to 200 kB each, 50 by default) and writes it atomically, on the main thread, every time the change count moves. Copying a large text while an answer streams can stall the stream. Fix: write on a background queue, or debounce by one second.

### P5. Small things on the hot paths (fine today, watch them)

- `CGWindowListCopyWindowInfo` on every open for the paste target: 1.1 ms ([SelectedTextService.swift:68](../Sources/Services/SelectedTextService.swift:68)). Acceptable.
- `learn()` saves the usage file synchronously before the app launches: 0.7 ms. Could move after `launch()`.
- `rankLauncherMatches` builds `systemCommands` three times per keystroke (roots count, caffeinate count, commands list) and formats a `Date` inside it: 16 µs each. Fine, but `catalogCount` could read cached counts.
- `FuzzyMatcher.fold` re-folds every title on every keystroke (0.28 ms of the 1.3 ms). Pre-fold once per catalog load if typing ever needs to be faster.
- `applicationMatches` ([QuickViewModel.swift:250](../Sources/ViewModels/QuickViewModel.swift:250)) is a second, uncached ranking pass that the UI no longer uses; only tests call it. Delete or mark test-only so nobody wires it into a view again.

### Not a performance bug, but found on the way

- `ApplicationCatalogService` scans once at launch and never again ([ApplicationCatalogService.swift:8](../Sources/Services/ApplicationCatalogService.swift:8)). An app installed today is invisible until relaunch. A `DispatchSource` on the `/Applications` folders, or a rescan on each open if the folder mtime changed, fixes it for free.

## 3. Vorssaint: what is worth bringing in

Vorssaint (`vorssaint/vorssaint-utils`) is a menu-bar bundle: volume mixer, system monitor, app switcher, window snapping, Dock previews, clipboard history, snippets, shelf, screenshots and recording, cleaner, uninstaller, Homebrew manager, keep awake, displays, and a **Command Bar**. It is GPL 3 with a trademark clause, so nothing is copied; ideas only.

Most of it is a different product (drivers, monitors, daemons, permissions). The Command Bar is the part that overlaps with Quick Launch, and a handful of its rows fit the five primitives with almost no code or runtime cost.

### Take (small, fits an existing catalog, no new permission)

| Vorssaint feature | Quick Launch shape | Size |
|---|---|---|
| Typed web address opens in the browser | An `Open URL` item when the root query looks like a host or URL; uses the Quick Link browser setting | tiny; also resolves part of the Return ambiguity |
| Sums, conversions, dates as you type | Extend the local path: units (km↔mi, kg↔lb, °C↔°F, GB↔MB), `3 days from now`, `next friday`, time in a city. Offline, deterministic, same tier as math | small |
| System Settings panes one row away | A static list of ~30 `x-apple.systempreferences:` URLs with keywords in the Commands catalog | tiny, zero runtime cost |
| ⌘K on an app: Quit, Force Quit, Hide, Relaunch | Four `ItemAction`s on application rows via `NSRunningApplication` | tiny |
| Apps answer to alternate names macOS knows | Read `kMDItemAlternateNames` per app once at launch (background) and feed it to `matchScore` as keywords | small |
| Copy text from a screen area (no AI) | `Copy Text from Screen Area`: the existing area selector plus the existing Vision OCR, result to the clipboard | tiny |
| Clean URL | `Copy Clean Link` ⌘K action on clipboard URLs and Quick Links: strip `utm_*`, `fbclid`, `gclid`, `si`, `ref` | tiny |
| Paste as plain text | One command with a hotkey: plain string of the current clipboard pasted to the previous app (paste path already exists) | tiny |
| Quick toggles | Dark mode, Lock Screen, Empty Trash, Eject All, Show Hidden Files, Hide Desktop Icons as Commands. `defaults`/`osascript` via `Process` with argv arrays, no shell | small; dark mode and Empty Trash need one-time Automation approval for System Events/Finder |

### Maybe later (medium, real value, some cost)

- **Open windows as rows** ("switch to a window"): `WindowManager` already lists on-screen windows; adding them to the root list gives Return-to-focus-window. Needs the window list on every keystroke (1 ms) or on open; fine.
- **Menu commands of the frontmost app** (run any menu item, shows its shortcut): strong feature, but walking the AX menu tree of a big app costs hundreds of ms and needs a per-app cache. Only with a cache built off the hotkey path.
- **File search in named folders via Spotlight** (`NSMetadataQuery`): useful, but `docs/product-scope.md` keeps document workflows outside the core. Decide scope first.

### Leave out

Volume mixer, system monitor and alerts, app switcher, Dock previews, mouse and keyboard drivers, smooth scrolling, Super key, shelf, screen recording and its editor, camera preview, scratchpad, cleaner, uninstaller, Homebrew manager, app updates, displays and extra brightness, Music blocker, disk image installer, bug reports from the bar, local scripts with output in rows (outside the safety boundary). Each is a product of its own, adds a permission or a background process, and conflicts with "keep the overlay small and fast".

One idea worth keeping as a principle, not a feature: Vorssaint's "what you uninstall stops loading and costs nothing". Quick Launch already does this for OCR and clipboard polling; keep it true for each item above (nothing polls, nothing loads until the row is used).

## Suggested order

1. Return rule + `Ask AI` row + tests (section 1). Half a day. Changes what the product *is*.
2. P1 delta coalescing and P2 clipboard change-count cache. An hour each, the two biggest felt wins.
3. P3 icon cache, P4 background clipboard save.
4. Vorssaint "take" list, one item per commit, in the order of the table.

---

# Part 2 (same day): what was built, and the open questions

## Built, tested, not yet run by hand

Everything below is in the working tree, uncommitted. `swift test`: 560 tests, 55 suites, green. `SIGN_IDENTITY=- ./scripts/build-app.sh` produces a valid `build/Quick Launch.app`. Nothing was launched; the items marked **runtime unverified** need one manual pass.

| Item | Where | Status |
|---|---|---|
| Return rule: Ask AI is a row; one word → launcher first, prompt-shaped text → Ask AI first; exact name / prefix / phrase-in-title / alias / learned pick still win | `AskAIRanker.swift`, `QuickViewModel.rankLauncherMatches` | tested (`AskAITests`) |
| Ask AI learns, pins, aliases, hotkey, empty-root row | same | tested |
| `⇥` Tab → Ask AI mode with the typed text kept; `/alias` completion first | `handleTab`, `enterAskAIMode`, `InputMode.askAI` | tested |
| Stream coalescing (33 ms), Markdown memo, text view re-layout only on change | `appendStreamText`, `MarkdownRenderer.cachedRender`, `MarkdownTextView.Coordinator` | tests pass; feel it on a long answer |
| Clipboard image decoded once per pasteboard change | `ClipboardImageReader` | runtime unverified |
| Icon cache + warm-up | `AppIconCache` | runtime unverified |
| Clipboard History writes off the main thread | `ClipboardHistoryStore.writeQueue` | tested |
| Apps folder rescan on open, alternate names, custom app paths | `ApplicationCatalogService` | runtime unverified (`kMDItemAlternateNames` confirmed with `mdls` on this Mac) |
| Local answers row: math, units, dates, city time (`LocalConversionResolver`) | `localAnswer(for:)` | tested |
| Typed URL → Open row | `TypedURLDetector` | tested |
| Folders catalog, `dl` / `dk` defaults, Add Folder…, open-or-front Finder window | `FolderLocationService`, Settings › Items › Add | plan tested; the AppleScript front-or-open is **runtime unverified** (first use asks for Finder automation) |
| ⌘K on a running app: Hide, Quit, Relaunch, Force Quit | `controlRunningApplication` | runtime unverified |
| Quick toggles (8) | `QuickToggleService` | plans tested; **never executed** (dark mode, lock screen, empty trash need a by-hand check; Lock Screen uses ⌃⌘Q through System Events) |
| System Settings panes (45) | `SystemSettingsPaneCatalog` | identifiers verified against `Sidebar.plist` on this Mac; 4 flagged in the file's comment; none opened |
| Copy Text from Screen Area (OCR to clipboard) | `copyTextFromScreenArea` | runtime unverified |
| Paste as Plain Text, Clean Link on Clipboard, `⌘⇧U` Copy Clean Link | `performSystemCommand`, `URLCleaner` | cleaner tested; paste path reuses the existing snippet paste |
| Lists show 12 rows | `maxLauncherRows`, `PanelSizing` | tested |

Manual pass to do: open the overlay, type `hi` then `⇥` then Return; type `dl`; type `12 km in miles`; type `dark mode` Return; ⌘K on Safari while it runs; Copy Text from Screen Area on a window with text.

## Network: does a request go through the VPN?

Today: `OpenAICompatibleService` uses `URLSession.shared`. That means

- requests follow the **system** route: a system proxy (ClashX, Surge, Helium's proxy) or a TUN-mode VPN carries them; there is no per-provider choice;
- connections are **reused** (one shared pool, keep-alive), so there is no extra TLS handshake per question unless the pool went idle;
- no timeouts are set (system default 60 s per request).

What would improve felt latency, in order:

1. **Route per provider** in Settings › Models: *System* (default), *Direct* (bypass the system proxy: `connectionProxyDictionary = [:]`; this skips proxy-based VPNs, not TUN VPNs), *Proxy* (host:port, for sending only DeepSeek through Clash while everything else stays direct, or the reverse). One `URLSession` per provider, created once.
2. **Time to first token** shown in the footer after each answer ("DeepSeek · 0.8 s"), and kept per provider so you can see which route is fast from where you are.
3. **Warm-up on open**: a tiny `GET /models` (or `HEAD`) to the selected provider when the overlay opens, so the TLS handshake is done by the time you press Return. Costs one small request per open; make it a toggle.
4. **Per-request timeout** of 20 s for the first byte, with the error naming the route ("DeepSeek via proxy 127.0.0.1:7890 did not answer in 20 s").

None of this needs new permissions. Item 1 and 2 are a half day together.

## Settings, Vorssaint style

Vorssaint's settings win because of three things: a **sidebar** (every section visible, no tab strip), a **Features hub** (install / uninstall whole features, each with an honest energy badge), and **one place per permission** (what needs it, which features use it, revoke when unused).

Proposal for Quick Launch, keeping the current tables:

- Sidebar sections: General · Items (Apps, Folders, Snippets, Quick Links, Windows, Commands, one table, filter chips stay) · Prompts · Models · Network (the routes above) · Clipboard & Links · Permissions · About. Search field at the top of the sidebar that filters across sections (Raycast does this too).
- **Models**: provider list on the left, detail on the right: base URL, key status ("in Keychain", never the value), model picker, route, a **Test** button that reports time to first token, and a default marker. Add/remove providers here.
- **Prompts**: list left, editor right (name, alias, prompt, output behaviour, provider, hotkey), with a live preview of what `{selection}` expands to.
- **Permissions** page: Accessibility, Screen Recording, Automation (System Events, Finder), Input Monitoring if ever needed; for each: what uses it, granted or not, one button to the right pane of System Settings (the new pane catalog makes this free).
- **Features** toggles (Vorssaint's hub, smaller): Clipboard History, Screenshot OCR, Screen Awareness double-tap, Caffeinate Agent Watch, Folders, Toggles, each with what it keeps running ("polls the clipboard once a second", "nothing until used").

It is a UI rework of `SettingsView` (sidebar instead of `tabStrip`) plus two new pages; the data layer already exists. About a day.

## Omarchy / Hyprland navigation, and what transfers to macOS

What Omarchy does (Hyprland): Super+Return opens a terminal, windows auto-tile (dwindle) or scroll sideways, Super+Arrow moves focus, Super+Shift+Arrow swaps, Super+Shift+N sends a window to workspace N, groups (tabs of windows), "popped" floating windows that follow you, and a scratchpad overlay workspace.

macOS has no public API to tile other apps' windows into a layout engine, move a window to a Space, or make another app's window float above all Spaces. Tools that do it (yabai) need SIP changes; AeroSpace fakes workspaces by parking windows off-screen. So Quick Launch should not become a tiling manager.

What transfers cheaply, all through the existing `WindowManager` and per-item hotkeys:

- **Launch-or-focus hotkeys** (Super+Return terminal, Super+Shift+Return browser): already possible with per-app hotkeys; `NSWorkspace.openApplication` activates a running app. Worth shipping a suggested starter set on the Items page, not pre-bound.
- **Toggle app** (the scratchpad idea): one hotkey that shows an app if hidden and hides it if frontmost, for a terminal like Ghostty. Small.
- **Focus left / right / up / down** and **swap with neighbour**: the on-screen window list with bounds is already read for layouts; pick the nearest window in a direction, raise it (focus) or exchange frames (swap). Medium, no new permission.
- **Workspaces**: leave to macOS Spaces. If you want Omarchy-like workspace keys, run **AeroSpace** beside Quick Launch and let Quick Launch expose its CLI as commands (`aerospace workspace 2`, `aerospace move-node-to-workspace 2`, `aerospace focus left`) with aliases and hotkeys, shown only when the binary exists. That gives you Omarchy's navigation with ~80 lines here and zero new permissions.
- **Groups / popped windows / dwindle**: no.

## Other things worth adding (not built)

- **Snippet expansion by trigger while typing** (Vorssaint, Raycast, Tuna): out of scope for a launcher unless Tuna stops doing it.
- **Open windows as rows** ("switch to a window"): Return focuses it; ⌘K close, move to display. Medium.
- **Menu commands of the frontmost app** (Raycast's "Search Menu Items"): needs an AX menu walk cached per app; only with a cache built off the hotkey path.
- **Files by name in chosen folders** (Spotlight query, no index of our own): product-scope.md keeps documents out; decide first.
- **Preferences export/import** (Vorssaint): one JSON with settings, aliases, hotkeys, prompts; Keychain keys excluded. Small, useful for a new Mac.
