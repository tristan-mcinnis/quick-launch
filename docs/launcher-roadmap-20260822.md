# Launcher roadmap, 2026-08-22

Inputs: the Omarchy v3 manual (Hyprland hotkeys, clipboard, reminders), Sol
(source read: stores, native window manager, theme tokens), Quicksilver's
mnemonics (`QSMnemonics.m`, `QSObjectRanker.m`), and ueli's macOS extensions.
Lens: keyboard-first, sub-100 ms feel, small surface. Every item below is
scored against that lens, not against feature count.

## Shipped today

| Area | Change |
|---|---|
| Learning | `LauncherUsageStore`: Quicksilver-style mnemonics (typed text → chosen item, per scope) plus decayed frecency (14-day half-life). `cla` → Claude becomes first after one pick. Shorter and longer abbreviations inherit the lesson. Empty query shows the two most-used items above the catalog roots. Local JSON in Application Support, bounded (300 abbreviations, 400 items), toggle and "Forget" in Settings › General. |
| Ranking | One ranked list at the root: apps, commands, catalog roots, snippets, quick links. Learned picks outrank fuzzy text; an exact name still beats a related abbreviation. |
| Look | Monochrome tokens, blur material with dark tint, hairline border, inset rounded selection, Sol-style key-cap badges on rows that have a global hotkey, Raycast-style footer (context left, actions right). Dark is the default; explicit light choices survive migration. |
| Keys | Escape closes the overlay from anywhere (⌘K panes close first, a stream stops first). Backspace on an empty field returns to the root. Reopen always starts at the root. Opening Settings hides the launcher. |
| Windows | Maximize, Almost Maximize, Center, Left/Right Two Thirds, Move to Next/Previous Display. Settings › Windows lists them with alias and hotkey. |
| Icon | Black macOS tile, white bolt. Menu bar keeps the bolt. |
| Screenshots | ScreenCaptureKit capture of the previous app's window or the display under the pointer, attached to the chat context; `⌘⇧S`/`⌘⇧D` in the overlay, two launcher commands with hotkeys. Vision model setting routes images (local MLX default, DeepSeek vision selectable). Follow-ups keep the image in memory. `⌘K` result actions: save as snippet, search the web, copy, paste back. |
| Fix | 401 on model refresh: the Keychain item was saved under the old `apfel-quick` service name. `APIKeyStore` now reads legacy services and migrates the key forward. Refresh errors say what to do. |

## Tuna Companion sunset

Tuna Companion (`com.example.TunaCompanion`) shipped eleven scripts:
Caffeinate, Caffeinate Agent Watch, Caffeinate Status, Caffeinate Until,
Decaffeinate, OCR Screen to Clipboard, Copy Latest Screenshot, Screenshots,
Translate, Translate to Chinese, Translate to English. Status against Quick
Launch:

| Companion feature | Quick Launch today | Gap before Companion can go |
|---|---|---|
| Caffeinate on/off, status | ✅ native toggle in Commands and the menu bar | none |
| Caffeinate Until (timed) | ✅ commands for 30 min, 1 h, 2 h, 4 h, self-expiring | none |
| Caffeinate Agent Watch (stay awake while agent sessions run, battery aware) | ✅ same hook-file signal, both folders watched, 12 h stale sweep, 20% battery cutoff, native assertions | re-point the hooks at `scripts/quick-launch-agent-event` (your call; `~/.claude/settings.json` is yours) |
| Screenshots hotkey (capture to file and paste) | ✅ capture to chat context (`⌘⇧S`, `⌘⇧D`, commands with hotkeys) | file-saving variant not ported; macOS `⇧⌘4` already covers it |
| Copy Latest Screenshot | ✅ "Attach Latest Screenshot" command | none |
| Screenshot text index (OCR search over `~/Desktop/Screenshot*.png`) | ✗ by design | Spotlight already indexes text inside images on Apple silicon (Live Text). Replace with a Quick Link to a Finder search, or a `screenshots` catalog that lists recent files by name. The 1.1 MB `screenshot-text-index.json` can be deleted. |
| OCR Screen to Clipboard | ✗ by design (scope doc) | keep out unless the scope changes; Vision framework `VNRecognizeTextRequest` on a captured region would be ~80 lines if it ever comes in |
| Translate, Translate to Chinese/English, last target memory, translation history | ✅ `⇧↩` picks the direction from the script; `/translate` and `/zh` act on selected text; history is the quick-action history | none |
| Runtime status file, permissions report | ✗ | not needed; Settings shows Accessibility and Screen Recording state |

Order to retire it: (1) re-point the Claude Code and Codex hooks at
`scripts/quick-launch-agent-event` (needs your OK; it edits your hook files),
(2) remove the Companion's launchd items and hotkeys, (3) delete
`~/Library/Application Support/Tuna Companion` (the 1.1 MB OCR index goes with
it), (4) delete `/Applications/Tuna Companion.app`. Tuna itself (the snippet
store) stays until Quick Launch owns the snippet file. Not ported on purpose:
OCR text search over screenshots and pinyin under translations.

## Gap analysis

Legend: ✅ have, ◐ partial, ✗ missing. "Fit" is the keyboard-first/speed score
(high, medium, low, no).

### From Sol

| Feature | Quick Launch | Fit | Note |
|---|---|---|---|
| Frequency + recency ranking | ✅ (stronger: per-abbreviation) | high | Sol only gates on "ever used"; Quicksilver's explicit abbreviation list is the better model and is what shipped. |
| Hotkey badges on rows | ✅ | high | |
| Footer key hints | ✅ | high | |
| ⌘↩ web search on the query | ◐ (`/search`, auto-detect) | high | Cheap win: ⌘↩ anywhere runs SearXNG on the typed text. |
| ⇧↩ translate query | ✅ | | |
| Inline calculator | ✅ | | |
| Unit and timezone conversion inline | ✗ | medium | Extend `MathExpressionDetector` with `10 usd in cny`, `3pm tokyo`. Deterministic, local. |
| Emoji picker | ✅ Emoji & Symbols catalog | | |
| Clipboard manager with images | ◐ text only | medium | Images conflict with the no-persist rule for screenshots; keep text. |
| Scratchpad note | ✗ | low | Out of scope (not an action). |
| Process killer | ✗ | medium | Catalog from `NSWorkspace.runningApplications`; "Quit", "Force Quit". Native API, no shell. |
| System preference panes | ✗ | high | `x-apple.systempreferences:` URLs for the common panes (Wi-Fi, Bluetooth, Displays, Accessibility, Privacy). Type `blue` → Bluetooth pane. |
| System commands (sleep, lock, empty trash, toggle dark mode) | ✗ | high | Lock = `SACLockScreenImmediate` or `pmset displaysleepnow`; appearance toggle via AppleScript to System Events; confirm on restart/shutdown. |
| Window cycling (half → third → two-thirds on repeat) | ✗ | medium | Track last layout per window id in `WindowManager`. |
| Quarters | ✗ | medium | Four more `WindowLayout` cases. |
| Move to next/previous Space | ✗ | low | No public API. Sol fakes it with a synthetic drag plus ⌃→. Fragile; skip. |
| User scripts folder | ✗ | medium | `~/.config/quick-launch/scripts`, run with `Process` and argv, never a shell string. |
| Browser bookmarks | ✗ | low | Helium/Chromium `Bookmarks` JSON is readable; adds catalog noise. Only if aliased. |
| Hyper key (Caps Lock → ⌘⌃⌥⇧) | ✗ | medium | Needs `hidutil` at login; one-line launchd. Document, do not ship in-app. |
| Calendar in menu bar | ✗ | no | Not an action. |

### From Omarchy (Hyprland)

| Feature | Quick Launch | Fit | Note |
|---|---|---|---|
| Direct app hotkeys (Super+Return terminal, etc.) | ✅ per-app hotkeys | high | Ship a starter set on first run: ⌥⌘T terminal, ⌥⌘B browser? Better: leave blank, learning covers the launcher path. |
| Workspace jump (Super+1..4) | ✗ | medium | macOS: enable Mission Control shortcuts (⌃1..9) in System Settings. Quick Launch can post the key event (`CGEvent`) for "Switch to Desktop N" commands. Works only if the user enabled them. Offer as commands with a one-time setup hint. |
| Move window to workspace | ✗ | low | Same private-API wall as Sol. |
| Focus window in direction (Super+Arrow) | ✗ | medium | AX: enumerate on-screen windows, pick nearest centroid in the direction, `AXRaise`. ~150 lines, test the geometry pure. |
| Swap windows in direction | ✗ | low | Needs two AX writes and state; after focus-in-direction. |
| Grow/shrink (Super+=/−) | ✗ | medium | Resize by ±10 % of screen width from the current frame. Pure math plus one AX write. |
| Toggle floating/tiling, groups, scratchpad workspace | ✗ | no | Compositor features. |
| Unified clipboard hotkeys | ✅ ⌘⇧V history | | |
| Reminders (`omarchy reminder 7 'Tea'`) | ✗ | high | `remind 7 tea ready` → local `UNUserNotification` after N minutes. Deterministic, no model. |
| Notices: time, battery, weather | ◐ time via facts | medium | Battery via `IOPSCopyPowerSourcesInfo`. Weather needs network; skip. |
| Text extraction (OCR region) | ✗ | no | Outside core per scope doc. |
| Dictation | ✗ | no | `local-dictation-202605` already owns this. |
| Show all hotkeys (Super+K) | ◐ ⌘K shows actions | high | Add a "Keyboard Shortcuts" command that lists every bound hotkey (main, clipboard, apps, items, saved prompts) in one searchable pane. |
| Theme picker | ◐ dark/light | low | Monochrome is the theme. One accent toggle at most. |

### From Quicksilver

| Feature | Quick Launch | Fit | Note |
|---|---|---|---|
| Abbreviation mnemonics | ✅ | | Shipped with decay, which Quicksilver lacks. |
| Implied use counts feeding score | ✅ frecency | | |
| "Assign abbreviation" action | ◐ alias in Settings | high | Add "Set abbreviation…" to the ⌘K pane so it is done in place. |
| Return-key repeat fast path | ✗ | low | Niche. |
| Recent objects catalog | ◐ favourites on empty | medium | A "Recent" root listing the last 20 used items. |

### From ueli

| Feature | Quick Launch | Fit | Note |
|---|---|---|---|
| Spotlight-backed app discovery | ✗ directory scan | medium | `NSMetadataQuery` for `com.apple.application-bundle` catches apps outside the six roots (Homebrew casks in odd places, Setapp). Keep the scan as fallback. |
| Workflows (ordered actions with confirm) | ✗ | medium | Later; needs a safety design per scope doc. |
| Favorites pinning | ◐ learning | low | Learning makes this unnecessary. |
| Shell-interpolated commands | avoid | | ueli templates user input into `exec`. Quick Launch's direct `Process` rule stays. |

## Ranked next steps

Ordered by value for a keyboard-first daily driver divided by cost.

1. **System Settings panes and system commands catalog.** One new
   `SystemCatalog` with ~20 deterministic items: panes by URL, Lock, Sleep
   Display, Empty Trash (confirm), Toggle Appearance, Quit Quick Launch.
   Searchable at the root, learnable, hotkey-able. Half a day.
2. **⌘↩ web search and ⇧↩ translate on the typed text.** Two key bindings,
   no new UI. Footer already shows hints. One hour.
3. **Keyboard Shortcuts pane.** One command that lists every hotkey, fuzzy
   searchable. Answers "what did I bind to ⌥⌘L?". Two hours.
4. **Reminders.** `remind 15 stand up` → notification. Pure local. Two hours.
5. **Window: quarters, grow/shrink, layout cycling.** Extends existing
   `WindowLayout`/`WindowManager`. Half a day. Focus-in-direction after that.
6. **"Set abbreviation…" in ⌘K.** In-place alias editing for any row. One
   hour.
7. **Spotlight app discovery as a second source.** Only if an app is missing
   in practice.
8. **Process manager.** Running apps catalog with Quit/Force Quit. Two hours.
9. **Emoji catalog.** Static table, paste action. Two hours.
10. **Desktop switching through Mission Control shortcuts.** Behind a setup
    check; document the System Settings step.

Not planned: Spaces window moves (private API), scratchpad notes, calendar,
OCR, dictation, image clipboard persistence, browser bookmarks by default.

## Speed: measured, and against Sol and apfel

Measured on this Mac (M-series, 253 apps, 22 commands, live Tuna snippets and
links, 120 learned entries), release-equivalent test build, 2026-08-22:

| Step | Cost |
|---|---|
| App catalog scan (once at launch) | 69 ms |
| Full ranking pass per keystroke (`s`) | 2.7 ms |
| Full ranking pass per keystroke (`saf`) | 1.5 ms |
| Footer hints (now served from the cached pass) | ~0 ms after caching |
| Hotkey badge lookup, six rows | 0.002 ms |
| App icons, six rows (NSWorkspace cache) | 0.09 ms per row |
| Panel height calculation | 0.000 ms |
| Clipboard image check on open | 1.4 ms |
| Installed bundle | 6.1 MB, one 6.2 MB binary |

Changes made on the back of this: the 90 ms fade-in is gone, the Accessibility
read of the selected text moved off the hotkey path (it ran before the panel
showed, with a 1 s timeout if the front app stalled), and the ranking pass is
cached so the view, footer, and panel sizer share one computation.

Not measured here: Sol itself (not installed). What the source shows: React
Native macOS 0.81 with the Hermes JS engine, MobX state, NativeWind styling,
and MiniSearch ranking in JavaScript. Every keystroke crosses the JS/native
bridge and runs Yoga layout; the window is a native `NSPanel` with an
`NSVisualEffectView`, so show/hide is native-fast once resident. React Native
desktop apps usually sit well above 150 MB resident and pay a JS bundle load
at cold start. Quick Launch is Swift and SwiftUI in one process with no bridge,
so on architecture alone it should be faster per keystroke and far lighter.

apfel is a separate concern: it is an HTTP server wrapper around Apple's
on-device model, started as a helper process and spoken to over localhost. On
this Mac it is not installed, the provider in use is DeepSeek, and
`ApfelServerKit` is only referenced by `ServerManager`. Two options:

1. Remove it: drop the package, `ServerManager`, the MCP editor (MCP only
   applies to the managed apfel route), and their tests. Keep the
   OpenAI-compatible client (rename `ApfelQuickService` to
   `OpenAICompatibleService`). Smaller binary, fewer moving parts, no helper
   process. About half a day.
2. Replace it with in-process Apple AI: macOS 26 exposes `FoundationModels`
   (`LanguageModelSession`, streaming) directly from Swift when Apple
   Intelligence is on. No process spawn, no HTTP, no dependency. About a day
   including tests, and it only matters if local on-device answers are wanted
   at all.

Done 2026-08-22: option 1. Option 2 is off the table; Apple Intelligence is not available here.

## Speed contract additions

- Learning adds one dictionary read per candidate; 100 ranking passes over
  the real app catalog stay under the existing 250 ms gate
  (`rankingAHundredQueriesStaysWithinBudget`); measured 1.5 to 2.7 ms each.
- The hotkey path does no Accessibility reads and no animation.
- The usage file is written on selection only, never on keystrokes.
- Nothing new runs on a timer.

## Privacy notes

- `launcher-usage.json` holds item identifiers and folded abbreviations only.
  No snippet or clipboard values. "Forget learned ranking" deletes it.
- The Keychain migration copies the key to the new service and leaves the old
  item in place. macOS may ask once to allow Quick Launch to read the legacy
  item; Always Allow ends the prompts.

## Addendum 2026-08-30: saved future task, voice targeting for Type to Click

Saved as a separate task to pick up later. Not scheduled.

**What:** speak a target instead of typing it while the Type to Click overlay
is open ("Save As", "sidebar", "text field"). The existing search pipeline
stays; speech becomes a second input feeding the same fuzzy filter, and the
top hit activates on a confirmation word or a short silence.

**Why it is cheap here:** Type to Click is search-only over real control
names, roles, and menu paths, with no generated hint codes, so every target
is already speakable. This is Voice Control's model with better search.

**Constraints from the ohr post-mortem**
(`docs/learnings/voice-input-ohr.md`):

- In-process `Speech` framework (`SFSpeechRecognizer`), never a subprocess
  helper. One entitlement, no child-TCC puzzle.
- The acceptance test is end-to-end on an installed, signed build: press the
  hotkey, speak, the right control activates.
- Distinct from dictation, which stays not-planned above (`local-dictation`
  owns typing by voice). This task is voice *targeting* only.

Origin: the Peekaboo comparison (`docs/peekaboo-comparison.md`).
