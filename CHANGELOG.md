# Changelog

## Unreleased

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
