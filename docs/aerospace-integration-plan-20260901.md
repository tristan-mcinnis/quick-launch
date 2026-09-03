# AeroSpace integration and Spaces plan, 2026-09-01

Inputs: the AeroSpace repo and docs (nikitabobko/AeroSpace, CLI reference,
config guide), the Quick Launch source map (settings, menu bar, process
execution, window management, command dispatch), and the standing verdict in
`docs/review-enter-perf-vorssaint-20260823.md` lines ~202-211: Quick Launch
must not become a tiling manager; run AeroSpace beside it and expose its CLI
as commands, shown only when the binary exists.

This plan keeps that verdict and extends it with the two things Tristan asked
for: an **AeroSpace mode** (Settings + menu bar) and **Spaces** (saved
multi-app screen setups, e.g. Slack on the MacBook left, WeChat right).

## 1. What AeroSpace gives us

- i3-style tiling with its own virtual workspaces (not macOS Spaces). No SIP
  disable; needs only Accessibility permission, which Quick Launch already
  explains in Settings for its own window commands.
- CLI-first: one binary `aerospace` with argv subcommands. Query commands
  (`list-windows`, `list-workspaces`, `list-monitors`, `list-apps`) support
  `--json` / `--format`. Action commands: `workspace N`, `focus left|...`,
  `move-node-to-workspace N`, `move-node-to-monitor`, `layout tiles|accordion|
  floating`, `summon-workspace`.
- Config is a user-owned TOML dotfile (`~/.aerospace.toml` or
  `~/.config/aerospace/aerospace.toml`) with `workspace-to-monitor-force-
  assignment`, `on-window-detected` rules, and `exec-on-workspace-change`.
- Install: `brew install --cask nikitabobko/tap/aerospace`. Not currently
  installed on this Mac; the whole integration must be dormant-by-default.

Fit with the Golden Goal: everything is `Process` + `executableURL` + argv,
no shell interpolation, no new permissions, no new persistence of window
content. Quick Launch stays the keyboard front-end; AeroSpace is the engine.

## 2. Architecture: sidecar, never engine

Three hard rules up front:

1. **Quick Launch never writes `aerospace.toml`.** The dotfile is the user's.
   Everything runs through the CLI at action time. If a Space would benefit
   from a permanent `workspace-to-monitor-force-assignment`, Quick Launch
   shows the TOML snippet to copy, it does not edit the file. This avoids the
   whole class of "the launcher clobbered my dotfiles" failures.
2. **Availability-gated everywhere.** `ExecutableResolver.resolve("aerospace")`
   (`Sources/Services/LocalModelDiscovery.swift:39`) is the single gate. Binary
   absent: no commands in the catalog, no menu bar item, Settings section shows
   an install hint with the brew command. Binary present but the app not
   running: actions return AeroSpace's own stderr as the error string.
3. **Spaces are engine-agnostic.** A Space describes intent (app X on screen Y,
   region Z or workspace N). With AeroSpace mode on, it applies via the
   `aerospace` CLI. With it off, it applies via the existing AX
   `WindowManager` + `WindowLayout` fractional frames, which already do
   "Slack left half, WeChat right half" today. AeroSpace is an upgrade, not a
   dependency.

## 3. Phase 1 — AeroSpace command lane (~1 short session)

The ~80-line integration the review doc already endorsed.

- `Sources/Services/AeroSpaceService.swift`: protocol `AeroSpaceCommanding`
  plus a pure `ProcessPlan`-style argv builder, copying the
  `QuickToggleService` shape (`Sources/Services/QuickToggleService.swift:150`).
  Execution reuses the `CommandActionRunner` pattern (resolve, run detached,
  capture stdout/stderr, map non-zero exit to a short user string).
- Catalog: `aerospaceCommands` computed property beside `systemCommands` in
  `QuickViewModel` (line ~541), value prefix `aerospace.`, only when the
  binary resolves. Initial set: Workspace 1-9, Workspace Back-and-Forth,
  Focus Left/Down/Up/Right, Move Window to Workspace 1-9, Move Window to
  Next Monitor, Layout Tiles/Accordion/Floating for the focused window,
  Balance Sizes. Because they join the one ranked list, aliases, learned
  mnemonics, pinning, and per-item global hotkeys all come free via
  `LauncherItemConfiguration`. `ws 3` as a typed alias becomes muscle memory
  the same way `cla` did.
- Dispatch: one branch in `performSystemCommand`
  (`Sources/ViewModels/QuickViewModel.swift:3541`) before the `window.` guard.
  AeroSpace commands do not need a `selectionTarget`; do not inherit that
  requirement.
- Settings: extend the `ItemsSettingsView.Filter` windows case or add an
  `aerospace` case mirroring the `window.` prefix filter (line ~86).
- Tests: `Tests/AeroSpaceTests.swift` asserting argv construction and catalog
  gating with no subprocess, matching `QuickToggleServiceTests`.

## 4. Phase 2 — AeroSpace mode (Settings + menu bar)

"Mode" means: Quick Launch knows AeroSpace is the active window engine and
behaves accordingly.

- `QuickSettings`: `aerospaceModeEnabled: Bool = false` (decodeIfPresent, no
  version bump needed) plus `aerospaceShowInMenuBar: Bool = true`.
- Menu bar (`AppDelegate.buildContextMenu()`, line ~1063): when the binary
  resolves, a submenu **AeroSpace** with: mode on/off toggle, current
  workspace indicator (from `list-workspaces --focused`), Workspace 1-5 jump
  items, and the Spaces list from Phase 3. Refresh the indicator lazily on
  menu open, never poll. Optional later: subscribe to
  `exec-on-workspace-change` via a tiny handler for a live workspace number
  in the status item; skip in v1, it violates the no-idle-work instinct.
- Behavior changes when mode is ON:
  - The 26 fractional `WindowLayout` commands stay available (AeroSpace
    floats a window on demand), but each AX write invalidates
    `WindowManager.lastApplied` anyway; additionally, an AeroSpace-tiled
    window will be re-tiled the moment AeroSpace acts on it. Mitigation:
    when mode is on and a `window.` layout is invoked, prepend
    `aerospace layout floating` for the focused window so the AX frame
    sticks. This is the one real seam between the two systems; make it
    explicit, test the plan (argv sequence) purely.
  - Restore (`WindowMove.restore`) keeps its single-slot in-memory contract;
    document that AeroSpace re-tiles can make it a no-op. Do not try to make
    restore fight the tiler.
- Settings UI: a subsection under the Windows area (or the proposed sidebar's
  Features hub): mode toggle, menu bar toggle, binary path + detected version
  (`aerospace --version`), install hint when absent, and the Spaces editor.

## 5. Phase 3 — Spaces (saved setups)

The new capability. A **Space** is a named, keyboard-summonable description of
"how my screens should look", e.g. `focus`: Slack on the built-in display left
two-thirds, WeChat right third; browser maximized on the external.

### Model

`Sources/Models/SpaceSetup.swift`, pure and Codable, stored in
`QuickSettings` like saved prompts:

```swift
struct SpaceSetup {            // "Space" clashes with SwiftUI.Spacer mental space; SetupSpace/SpaceSetup
    var id: UUID
    var name: String           // "focus", "calls", "china"
    var alias: String?         // typed alias, same lane as saved prompts
    var hotkey: ActionHotkey?
    var placements: [Placement]
    struct Placement {
        var bundleID: String           // com.tinyspeck.slackmacgap
        var appName: String            // display fallback
        var display: DisplayTarget     // .builtIn, .main, .secondary, .index(n)
        var region: WindowLayout?      // engine-agnostic fractional frame
        var workspace: String?         // AeroSpace workspace name, used in mode
        var launchIfNeeded: Bool
    }
}
```

`DisplayTarget` mirrors AeroSpace's monitor patterns (`main`, `secondary`,
`built-in`, index) so one description drives both engines.

### Apply semantics (the resolver is pure, test it hard)

`SpaceSetupResolver.plan(setup:engine:displays:runningApps:)` returns an
ordered step list; execution is a thin loop.

1. For each placement, launch-or-focus the app (`NSWorkspace` by bundle ID;
   `launchIfNeeded` false means skip absent apps silently).
2. Engine = AeroSpace mode ON: `aerospace move-node-to-workspace <ws>` for the
   app's windows (window IDs from `list-windows --app-bundle-id ... --json`),
   then `aerospace workspace <ws>` / `summon-workspace` per display. Monitor
   pinning beyond the session is the user's TOML; Quick Launch offers the
   snippet.
3. Engine = plain AX: for each placement, resolve the display by
   `DisplayTarget` against `NSScreen.screens`, compute the frame via the
   existing `WindowLayout.frame(in:)`, apply through `WindowManaging`. This
   reuses `relocatedFrame` math already tested in `WindowLayoutTests`.
4. Degraded screens: if a placement's display is absent (external unplugged),
   fold it onto the built-in display in declaration order rather than fail.
   One display today is the common case on the road; a Space must still mean
   something on one screen.

### Capture, not authoring

Hand-writing placements is friction. Add **"Save Current Setup as Space"**
(command + ⌘K action): read the current arrangement via
`CGWindowListCopyWindowInfo` (already used in `WindowManager`) or
`aerospace list-windows --json` in mode, snap each frame to the nearest
`WindowLayout` fraction, and pre-fill the editor. Editing then happens in a
Spaces tab section modeled on `SavedPromptsEditor`.

### Surfacing

- Catalog items with prefix `space.` in the ranked list: `focus` typed alias
  applies the Space, hotkeys work without opening the panel (direct-hotkey
  contract already exists).
- Menu bar: Spaces listed in the AeroSpace submenu (and in the plain menu
  when mode is off, since Spaces work without AeroSpace).
- ⌘K on a Space: Apply, Apply to Built-in Only, Edit, Delete (guarded).

## 6. What stays out (scope guard)

- No tiling logic, tree management, or workspace emulation in Quick Launch.
- No writing or migrating `aerospace.toml`; no launchd/login management of the
  AeroSpace app.
- No polling AeroSpace state, no background subscriptions in v1.
- No per-window persistence beyond the `SpaceSetup` declarations (frames of
  live windows are read at capture time, never stored as history).
- Groups, scratchpads, dwindle layouts: still rejected, per the review doc.

## 7. Order of work and effort

| Phase | Content | Size |
|---|---|---|
| 1 | AeroSpaceService + command lane + tests | ~1 session, small |
| 2 | Mode flag, menu bar submenu, floating-before-AX seam | ~1 session, small |
| 3 | SpaceSetup model + resolver + AX engine + capture + editor UI | 2-3 sessions, the real feature |
| 3b | AeroSpace engine for Spaces (workspaces per display) | ~1 session on top |

Phase 3 with the AX engine is useful even if AeroSpace never gets installed;
Phases 1-2 are nearly free and make AeroSpace a first-class citizen the day it
is. Suggested first commit: Phase 1 exactly as the review doc scoped it.

## 8. Open questions

1. Naming collision: the feature name "Spaces" vs macOS Spaces. In-product
   copy could say "Setups" or "Scenes" to avoid support confusion; the
   catalog prefix `space.` is fine either way.
2. Should applying a Space also switch AeroSpace workspaces on both monitors
   (`summon-workspace`), or only arrange windows and leave focus where it is?
   Recommend: arrange + focus the first placement's workspace.
3. WeChat has multiple window types (main, chats, moments). v1 places the
   main window only (largest on-screen window per app, same heuristic
   `WindowManager` already uses); per-window matching is a later refinement.
