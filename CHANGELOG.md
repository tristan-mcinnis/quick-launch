# Changelog

## Unreleased

- Colors catalog and a screen colour picker, after Raycast's Color Picker. **Pick Color from Screen** opens AppKit's own magnified loupe over every display, and the pixel you click is copied in the notation set in Settings › Clipboard & Capture (Hex, RGB, HSL, or HSB). The panel does not come back: pick, copy, done. **Pick Color and Paste** sends it to the app behind the panel as well. Each pick is kept in a local, bounded, owner-only history (`color-history.json`, numbers only, no pixels) that appears as the Colors catalog: a swatch preview beside the list with Hex, RGB, HSL, HSB, the nearest colour name, and when it was picked. `⌘1`…`⌘4` copy the other notations, `⌘↩` copies, Return pastes, `⌘⇧P` pins, `⌘⇧N` saves a snippet, `⌃X` deletes. Colours are searchable by name and by any notation ("steel", "rgb(74"). The picker needs no screen recording permission and stores no image.
- Text from Screen gains **Paste Text from Screen Area** beside the existing copy command, and a line-break preference: on keeps the layout Vision found (code, lists), off joins the lines into one paragraph (prose).
- Emoji & Symbols takes a skin tone (Settings › Clipboard & Capture). It applies to every emoji with a modifier base, replaces an existing tone rather than doubling it, leaves symbols and flags alone, and keeps item identifiers stable so pins and Frequently Used survive the change.
- Settings tab "Clipboard & Links" is now "Clipboard & Capture" and holds the Colors, Emoji & Symbols, and Text from Screen sections.
- Launcher lists show one row per catalog plus three, so two favourites, Ask AI, and every catalog root still fit as catalogs are added.

- Snippets and Quicklinks get the Clipboard History preview: the selected row opens the two-pane layout and shows what the item actually holds. A snippet shows its full text (scrolling when long) with Characters, Words, Lines, and Source; a quick link shows its title and target URL with Type (Link or Smart Link), Site, Characters, and whether it needs input. Pinned items say so. Nothing new is stored: the pane reads the live catalog value.
- Screen History is one local catalog with debounced FTS search across the owned SQLite store and the closed Coast database. Rows keep a stable order and show the matched text, time, application, context, and an Owned or Coast source cue. The selected row uses the standard two-pane preview. Return opens the moment; Command-Y opens its local timeline; Command-Return copies the recognized text; Command-K offers Open moment, Show timeline, Copy text, Show in Finder when a local file exists, and Save to Vault. Search parses `app:`, `site:`, `after:`, `before:`, today, and yesterday. Future-screen questions refuse and current-project questions point to Vault Search without calling it. Legacy search is independent of capture. This search-only beta hard-locks owned capture in Settings, bootstrap, configuration, and commands. The latent capture path requires FileVault and visible consent, refuses all browsers plus protected apps and sessions before pixels, and forces a stateful menu-bar control while active. Editable application and domain exclusions also filter local search and legacy migration.
- Vault Search is a first-class catalog beside web search and Ask AI. Its four items are Current Project, Reconcile Changes, Project History, and Across Projects. Every mode calls the VPS over the existing SSH connection, sends the query on stdin, and renders a compact cited answer in the normal answer surface. Current and reconciliation combine project state, tasks, decisions, email, meetings, Slack, and project files; history retrieves explicit archived versions; portfolio searches current project state. Ambiguous scope shows project choices, future questions refuse before retrieval, and typed follow-ups stay on Vault Search instead of switching to the selected AI model. The structured route makes one product call and no model-provider request.
- Quick AI reads web pages: a prompt that contains an http(s) URL fetches the page (direct URLSession first, the vault-vps trafilatura reader as fallback for thin or blocked pages), extracts readable text (up to 12k characters), and attaches it to the question as bounded untrusted context, so asking about a link gets an answer from the live page instead of "I cannot access external websites". Up to two URLs per prompt; a page that fails to read submits with a visible note instead of aborting.
- Chat browsing direction fixed: `⌘[` (Previous Chat) now steps backwards in time from the newest chat and `⌘]` (Next Chat) steps forward again; with no chat open either direction lands on the most recent chat instead of wrapping to the oldest.
- Folders open instantly: Return on Desktop (`dk`), Downloads, or any folder used to run an osascript that fronts a matching Finder window, and that Apple Event exchange could hang for a very long time (measured at 107 seconds once). It now uses the native `NSWorkspace` open directly, so the folder appears in Finder immediately; the front-the-existing-window nicety is gone.
- The Screenshots catalog is a pure file list, newest first with pins floated, so the latest capture is the first row. The capture and Screen Awareness commands (Send Focused Window / Screen / Screen Area to AI, Attach Latest Screenshot, Paste Latest Screenshot) are no longer inline rows; they appear in every ⌘K pane inside the catalog as searchable rows without shortcuts, stay searchable from the root, and keep their overlay shortcuts (`⌘⇧S`, `⌘⇧D`). Attach Latest Screenshot now fills in the Screen Awareness attachment card like its sibling captures.
- Screenshots search forgives plurals (`screenshots` now matches what `screenshot` did; short words like `lens` keep their exact form) and date words work anywhere in the query (`acme today`, `meeting 7d`, `2026-08-11 report`); conflicting date words degrade to no date filter. The catalog and its OCR index cover the newest 400 captures (was 240). The Screenshots root badge counts real files: the folder is scanned in the background at launch and whenever the overlay appears, and entering the catalog within two seconds of a scan skips the re-read, so entry is instant. Thumbnail memory is byte-budgeted (~64 MB), OCR text hits surface without waiting for another keystroke, and Paste Latest Screenshot understands every filename prefix the catalog lists (CleanShot included).
- Clipboard History paste repaired: Return could report success while nothing landed in the previous app. The text now goes to the clipboard before pasting, the accessibility insertion is verified by reading the field back (some apps accept it and silently drop it) with a synthesised Command-V as fallback, and a missing or quit captured target is re-resolved from the window stack so paste lands in the app behind the overlay. Pasted content stays on the clipboard instead of being restored away.
- Screen Awareness reads Finder like Raycast does: file paths highlighted in the front Finder window join the attachment card ("Files") and the model preamble, bounded to 20 files.
- The Return rule is now explicit: Return runs the highlighted row, and **Ask AI** is a row like any other. One word keeps the launcher first (`weather` opens Weather); two or more words, a question mark, or a leading verb (`what`, `write`, `fix`…) put Ask AI first; an exact name, a title prefix, a whole phrase inside a title, an alias, or a learned abbreviation still wins. Ask AI can be pinned, aliased, given a global hotkey, and it learns from use like every other row; it sits first on the empty root. `⇥` (Tab) switches whatever you typed to the AI from any search (Raycast's "Tab to Ask AI"); a `/alias` match still completes first.
- Answers as you type: math, unit conversions (`12 km in miles`, `72f to c`, `5 gb in mb`), date arithmetic (`3 days from now`, `next friday`, `days until 2026-12-25`), and city times (`time in london`) appear as the top row. Return copies, `⌘↩` pastes. All local, no model.
- Typed web addresses (`apple.com/iphone`, `localhost:3000`) get an Open row that uses the Quick Link browser.
- Folders catalog: Home, Desktop, Documents, Downloads, Applications, Pictures, Movies, Music, Public, Library, iCloud Drive, plus folders you add in Settings › Items (Add › Add Folder…). Return opens the folder in Finder, or fronts the Finder window that already shows it; `⌘↩` reveals it; `⌘⇧C` copies the path; alias, hotkey, and pin work as everywhere. `dl` opens Downloads and `dk` the Desktop from the first run.
- Settings › Items › Add › Add App… registers an `.app` that lives outside the Applications folders. Apps installed while Quick Launch runs now appear without a relaunch (the Applications folders are checked on each open), and apps answer to the alternate names Spotlight knows (`System Preferences` finds System Settings).
- `⌘K` on a running app: Hide (`⌘⌥H`), Quit (`⌘⇧Q`), Relaunch (`⌘⇧R`), Force Quit (`⌘⌥Q`); the primary action reads Switch To.
- Commands: Quick toggles (Toggle Dark Mode, Lock Screen, Empty Trash, Eject All Disks, Toggle Hidden Files, Toggle Desktop Icons, Sleep Display, Start Screen Saver), 45 System Settings panes (`bluetooth`, `privacy accessibility`…), Copy Text from Screen Area (on-device OCR straight to the clipboard), Paste as Plain Text, and Clean Link on Clipboard. `⌘⇧U` Copy Clean Link appears on clipboard entries and Quick Links that carry `utm_` or other tracking parameters. Toggles run `osascript`/`defaults` with fixed argument arrays, no shell; the first use of dark mode, Empty Trash, or Eject asks for Automation access.
- Performance: streamed tokens are published at most every 33 ms and the answer is re-rendered only when its text changes (was: a full Markdown parse and text re-layout per token); the clipboard image is decoded once per pasteboard change instead of on every open; app icons are cached and warmed after launch; Clipboard History writes its file off the main thread.

- Pin to Top (`⌘⇧P`, also in `⌘K`) now works on snippets, Quick Links, and screenshots, not only clipboard entries and chats. Pinned items sit at the top of their catalog above learned favourites, carry a small pin mark on the row, and rank ahead of unpinned matches when you type. The pin is stored with the item's alias and hotkey record and is dropped when the item is deleted or trashed.
- Translator window, after the Tuna Companion translator: its own panel on `⇧⌘T` (configurable in Settings › General), source above and translation below, retranslates as you type, opens with the selected text, direction from the text (CJK → English, otherwise the last target), `⌘P` target picker, `⌘S` swap that round-trips, `⌘↩` copy, `⇧⌘↩` paste back, `⇧⌘V` clipboard as source, pinyin under Chinese, copy or paste queued while a translation is still arriving. Committed translations are stored locally (500, 0600). The in-launcher Translate mode is gone; the Translate item opens the window.
- Window management rebuilt for accuracy: the window that is actually on top is resized (matched against the on-screen window list, not the app's "focused" window), `AXEnhancedUserInterface` is switched off during the change so Chromium and Electron apps (Helium, Slack, VS Code) resize correctly, size is set before and after position, the display is chosen by overlap, and the result is verified. Raycast's full command set is in: Maximize Height/Width, Reasonable Size, Center (keeps size), Center Half, Quarters, Sixths, Make Smaller/Larger, Move to edges, Restore, Toggle Fullscreen. Left and Right Half cycle on repeat.
- Streaming shows a subtle three-dot thinking indicator instead of a white stop square; Escape still stops.
- Answers get up to 560 px and earlier turns 240 px; the panel shifts up rather than running off the bottom of the display.
- Backspace on an empty field is now intercepted at the panel's `sendEvent`, so it pops a layer (attachment, answer, mode, catalog) even though the text field's editor swallows the key.
- Screenshots: Return on a file pastes the image into the previous app; `⌘⇧↩` attaches it to the question instead. Several screenshots can be attached to one question; Backspace removes the newest.
- Quick AI, after Raycast's Quick AI: Return on an answer pastes it back, typing follows up, earlier turns stay visible above the latest answer, `⌘N` starts a new chat, `⌘R` regenerates, `⌘[`/`⌘]` or `↑↓` browse recent chats. New Quick AI Chats catalog with Continue, Copy Last Answer, Rename (`⌘E`), Pin (`⌘⇧P`, pinned chats never expire), Delete (`⌃X`).
- Screenshots: on-device OCR (Vision, en/zh) indexes the text inside every screenshot into one local JSON file, so `acme` finds the invoice; matches from image text are marked. A preview pane beside the list shows the image, dimensions, size, date, and the recognized text. New actions: Paste Image to the previous app, and a Paste Latest Screenshot command.
- Emoji & Symbols is a 9-column grid with Frequently Used first; arrows move the highlight.
- Screen Awareness: Send Focused Window to AI attaches a screenshot plus the app name, window title, selected text, focused field, readable text, and page URL, read through Accessibility; Send Screen, Send Screen Area (drag a rectangle), and Send Selected Text cover the rest. A double tap of the right ⌘ key triggers it from anywhere (Settings › General). The attachment card lists what was included; the model gets the image plus a bounded text preamble.
- Clipboard History also shows a preview pane with character and word counts.
- Rebuilt Settings: a top tab strip instead of the system tab view that overflowed into a "»" menu, a wider window, `⌘1`…`⌘6` to switch tabs, and one Items table (apps, snippets, quick links, windows, commands) with alias and hotkey editable in place, Raycast-style.
- Answer state: while an answer is on screen the launcher rows are hidden, the question shows above the answer, and copy / paste back / save as snippet / search are keys (`⌘⇧C`, `⌘↩`, `⌘⇧N`, `⌘⇧W`) and `⌘K` actions instead of buttons. Backspace on an empty field pops back to the root.
- Clipboard History: `⌘⇧P` pins an entry to the top (pinned entries never expire), `⌘⇧N` saves it as a snippet, `⌘⇧L` saves a URL as a Quick Link. Both open the new item's editor.
- Quick Links open in the browser chosen in Settings › Clipboard & Links, or the system default.
- Screenshots catalog: capture commands first, then the saved files newest first (macOS and CleanShot names), with the Companion's date words (`today`, `yesterday`, `7d`, `last 30 days`, `2026-08-11`) and actions: Attach `↩`, Copy Image `⌘↩`, Quick Look `⌘Y`, Reveal `⌘⇧R`, Copy Path `⌘⇧C`, Trash `⌃X`.
- Translate as a mode: the Translate item (or `tr`) captures typing, arrives pre-filled with the selected text, `⇥` flips the direction, Return translates; the text shows above the translation.
- Caffeinate catalog with native power assertions (no child process): toggle, Caffeinate Until… (`17:30`, `5:30pm`, `90m`, `2h`), presets, Agent Watch, Status. Agent Watch reads the hook files Claude Code and Codex write (Quick Launch's folder and the Tuna Companion folder), holds sleep while a turn is running, pauses at 20% on battery, and restores intent after a relaunch. `scripts/quick-launch-agent-event` is the hook command.
- Launcher lists show up to nine rows so favourites and all seven catalogs fit.
- Added the Emoji & Symbols catalog (1 594 entries generated from Unicode 16 names with hand-written search words for the common ones): emoji, flags, arrows, math, currency, punctuation, and key-cap symbols. Paste with Return, copy with `⌘↩`.
- Added `⇧↩` translate: Chinese, Japanese, or Korean input goes to English, everything else to Simplified Chinese, through the `translate` and new `zh` saved prompts. The footer shows the direction before you press it.
- Added timed Caffeinate commands (30 minutes, 1, 2, 4 hours) that switch off by themselves, and "Attach Latest Screenshot", which attaches the newest file from the macOS screenshots folder.
- Launcher lists show up to seven rows so two learned favourites fit above the five catalog roots.
- Replaced the `⌘K` button rows with a Raycast-style action list: every action shows its shortcut, the list is searchable, and the same keys work without opening it (`⌘↩` secondary, `⌘⇧↩` copy and paste, `⌘E` edit, `⌘⇧A` alias, `⌘⇧H` hotkey, `⌃X` delete with a confirm step, `⌘⇧C` copy path for apps). Clipboard entries can be deleted one by one.
- The panel now opens with its input row on the display's centre line instead of a third of the way down.
- DeepSeek `deepseek-v4-flash-vision-exp` is the default model for text and screenshots. Settings still on the old defaults move over once; explicit choices stay.
- Removed the Apple on-device provider, the `apfel` helper process, the `ApfelServerKit` dependency, and MCP server configuration. Apple Intelligence is not available to this project. Old settings load unchanged; a stale Apple selection falls back to DeepSeek. `ApfelQuickService` is now `OpenAICompatibleService`. The package has one dependency (`swift-markdown`); `swift-testing` comes from the toolchain.
- Faster open: removed the 90 ms fade-in, moved the selected-text Accessibility read off the hotkey path (it is read only when an action needs it), and cached the ranking pass so the list, footer, and panel sizing share one computation per keystroke.
- Added screenshot attachments: "Screenshot of Previous App" and "Screenshot of This Display" are launcher commands with optional aliases and global hotkeys, and `⌘⇧S` / `⌘⇧D` attach one inside the open overlay. Captures use ScreenCaptureKit, stay in memory, exclude the overlay itself, and are capped at 2 560 px on the long edge. Backspace on an empty field removes the attachment.
- Added a Vision model setting (Settings › Models). Attached screenshots go only to that model; the local MLX server stays the default, and DeepSeek's `deepseek-v4-flash-vision-exp` is available once you choose it. Follow-up questions in the same thread keep the screenshot in memory; history never stores it.
- Added result actions to the `⌘K` palette: Save Result as Snippet (opens the new snippet's editor), Search the Web for Result, Copy Result, Paste Result Back.
- Snippet creation writes to the existing snippet store with the same timestamped backup as edits.
- Added launcher learning: the typed abbreviation and the item you chose are remembered per catalog, so that abbreviation ranks the item first next time; a decayed use count orders the rest, and the two most-used items appear above the catalog roots on an empty search. Stored locally in `launcher-usage.json`, with a toggle and a Forget button in Settings › General.
- Merged apps, commands, snippets, quick links, and catalog roots into one ranked root search.
- Restyled the overlay: monochrome tokens, blur material with a dark tint, hairline border, inset rounded selection, key-cap hotkey badges on rows, and a footer that shows the keys that work right now. Dark is the default appearance; an explicit light choice is kept.
- Escape now closes the overlay from anywhere (a ⌘K pane closes first, a running stream stops first). Backspace on an empty field returns to the root, and the next open always starts at the root. Opening Settings hides the launcher.
- Added window layouts Maximize, Almost Maximize, Center, Left Two Thirds, Right Two Thirds, and commands to move the window to the next or previous display.
- Replaced the app icon with a black tile and a white bolt. The menu-bar bolt is unchanged.
- Fixed HTTP 401 on model refresh and cloud requests: provider keys saved by earlier `apfel-quick` builds lived under the old Keychain service name. Keys are now read from the legacy service and migrated forward, and refresh errors say what to do.

- Added snippet Edit and guarded Delete commands to the keyboard-navigable `Command+K` pane; changes update Tuna's existing Custom Items store with a safety backup.
- Added empty-Backspace navigation from catalogues to the launcher root and a 15-second inactive catalogue reset.
- Added ephemeral clipboard screenshot attachments, automatically routed to the local MLX vision server without persisting image data in settings or history.
- Improved snippet pasting by targeting the topmost external window directly behind Quick Launch.
- Added a fully keyboard-navigable `Command+K` snippet action pane with Paste, Copy, and Copy & Paste.
- Fixed snippet Return pasting by dismissing the overlay before target-app activation and waiting for the previous app to become frontmost.
- Added previous-window layouts for left/right/top/bottom halves, all thirds, and all fourths, searchable by name with editable aliases and global hotkeys.
- Added a persistent native Caffeinate toggle in Commands and the menu-bar context menu; it is enabled by default for this migration.
- Kept local builds on one stable designated requirement so Accessibility approval survives rebuilds, and prevented generated build bundles from appearing as duplicate apps in Spotlight.

## v1.1.0 — 2026-08-21

- Added keyboard-first Snippets and Quick Links that read the existing Tuna stores live without copying private values into Quick Launch settings.
- Added optional, local, deduplicated, bounded text Clipboard History. `Command+Shift+V` opens it globally, arrows navigate, Return pastes to the previous app, and `Command+C` copies the selected item.
- Added a Catalogs settings tab for Tuna reload, item aliases, item hotkeys, clipboard retention, shortcut configuration, and clearing history.
- Added `/System/Library/CoreServices` to app discovery so Finder appears in search and can have an alias or global hotkey.
- Extended `Command+K` item actions and global hotkey registration across apps, snippets, and Quick Links.
- Moved result Paste Back to `Command+Return` so it does not conflict with Clipboard History.
- Added deterministic parsing, persistence, workflow, Finder, and interface regression tests.

## v1.0.13 — 2026-08-21

- Routed `Command+,`, the menu-bar item, and the overlay action to the real settings interface.
- Added a small semantic design-token layer for color, type, spacing, radii, control height, and motion.
- Made Copy and Paste Back visible 44-point controls with `Command+Shift+C` and `Command+Shift+V` shortcuts.
- Added an in-context button for opening Accessibility settings. Local ad-hoc builds now use a stable designated requirement so one fresh approval can persist across rebuilds.
- Removed automatic provider startup, model refresh, and update checks. Network and model work now begins only after an explicit action.
- Renamed the history clear-row label and tightened long-name, dark-mode, focus, and Reduced Motion handling.
- Added per-app aliases and global hotkeys. `Command+K` on a highlighted app opens its action pane, and Settings has one Apps editor for the same configuration.
- Fixed menu-bar clicks on a secondary display being dismissed as outside clicks.

- Kept the last result or draft for an adjustable 10-second quick-reopen window. Added an on-demand conversation transcript plus visible Copy and Paste Back actions under each completed reply.
- Added a 90 ms reduce-motion-aware open fade and placed the panel on the display containing the mouse pointer.
- Stopped automatic model discovery from running `lms`, which could launch a roughly 500 MB LM Studio service. Discovery now scans the model folder directly.
- Main launcher hotkey conflicts now show a settings error instead of failing silently.
- Added a cached fuzzy application launcher. Typing narrows visible app rows; arrow keys move selection and Return opens the selected app without an AI call.
- Added direct SearXNG retrieval for `/search` and common time-sensitive questions. The selected model receives five bounded, explicitly untrusted result snippets and writes the cited answer.
- Added performance gates for cached app matching. Quick search no longer fetches full pages, and slow search answers fall back to linked results.
- Reduced the input toolbar to Send and one menu for Quick Actions, model choice, history, and settings.
- Answer common date, time, day, and time-zone questions locally without an AI provider.

- Fixed the global hot key silently doing nothing without Input Monitoring permission. The app now registers its configurable shortcut through the native Carbon hot-key API, so the default `Option+Space` works without keyboard-monitoring access.
- Added selected-text quick actions through macOS Accessibility. Actions can show their result in the overlay or replace the selected text, with a copy fallback when replacement is unavailable.
- Added a keyboard-first `Command-K` action picker, fuzzy action search, and fuzzy slash aliases. `/eml` can find `/email`; Tab completes and Return runs the best match.
- Each action now has an editable name, prompt, alias, output behavior, provider, model, and optional global hotkey. Duplicate shortcuts are reported and not registered.
- Added `Control+Option+S` as the default Summarize shortcut.
- The follow-up input regains focus as soon as a response finishes.
- Made the overlay model control icon-only. The active model remains visible inside the menu and in its hover label.

## v1.0.8 — 2026-04-28

Fix: response text was unreadable in dark mode (issues #20, #23).

`MarkdownRenderer` was emitting attributed-string runs without `.foregroundColor`, so `NSTextView` fell back to a static text colour and rendered the response as black-on-dark. The fix sets `.foregroundColor: NSColor.labelColor` on every run — text, code blocks, headings, inline code, and the inter-paragraph newline runs. `labelColor` is a dynamic system colour that resolves per appearance, so the response now adapts in Light, Dark, and Auto.

- 32 markdown-renderer tests, including a new `testEveryGlyphCarriesLabelColor` that walks every character of a multi-paragraph render and asserts each carries `labelColor` (catches missed paths that single-range tests skip).
- No behaviour changes outside the renderer. Settings → Appearance → System / Light / Dark picker is unchanged.

## v1.0.7 — 2026-04-23

Removed the voice-input feature.

v1.0.5 and v1.0.6 shipped a microphone button backed by the `ohr` CLI. On installed, signed, notarized builds it never actually transcribed live microphone input — not once. Three successive patches (in-process `AVCaptureDevice.requestAccess`, audio-input entitlement, single-line entitlement XML for the AMFI kernel parser) each fixed a visible layer without fixing the end-to-end path. Rather than keep patching a subprocess architecture that fights macOS TCC + Hardened Runtime at every turn, the feature is removed in full.

- Mic button, Voice settings tab, `ohr` subprocess wrapper, microphone permission shim, voice fixture + tests — all deleted.
- `NSMicrophoneUsageDescription` removed from Info.plist.
- `com.apple.security.device.audio-input` removed from entitlements.
- Bundled `ohr` helper removed from the build script; releases no longer carry it.
- Full post-mortem kept at `docs/learnings/voice-input-ohr.md` so the next attempt at voice input doesn't repeat these mistakes. Recommendation: use Apple's in-process `Speech` framework, not a spawned CLI.

258 tests green.

## v1.0.0 — 2026-04-11

First public release.

- Global hotkey overlay (default: Ctrl+Space)
- Streaming AI replies via apfel, token by token
- Auto-copy result to clipboard (configurable)
- Local math calculator — expressions like `54,34*6-(435353)` compute instantly, no AI round-trip
- European decimal comma support
- Menu bar icon (optional)
- Launch at login (default on)
- In-app update checks via GitHub Releases
- First-run welcome overlay
- 168 tests, TDD-first
- MIT license
