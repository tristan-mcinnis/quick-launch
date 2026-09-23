# Quick Launch

**A keyboard-first macOS launcher and instant AI overlay.**

![Platform: macOS 26+](https://img.shields.io/badge/platform-macOS%2026%2B-black)
![Swift 6.2](https://img.shields.io/badge/swift-6.2-orange)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

Press `Option+Space`, or a hotkey you choose, and one search field opens over
whatever you are doing: launch an app, run a command, rearrange a window,
translate a selection, or ask an AI. `Tab` turns the panel into a chat, and
`Command+J` moves that chat into a full window. It lives in the menu bar, stays
fast and keyboard-first, and runs local actions without a model.

Almost everything is yours to change: the global hotkey, the in-app keys,
per-item aliases and hotkeys, the catalogs, and the model providers. Quick
Launch exists so the launcher's inner workings stay open to you and new rows
and actions can be added, instead of waiting on someone else's roadmap.

## Features

**Launcher**

- One ranked search across apps, folders, commands, snippets, quick links,
  saved actions, and the Ask AI row.
- Fuzzy matching, per-item aliases, optional per-item global hotkeys, and
  learned ranking with decay.
- Nested catalogs, keyboard-only navigation, and footers that show the keys
  that work right now.

**Instant answers, no model**

- Math, unit conversions, dates, and city times are computed on this Mac.
- Answers appear as you type; `Return` copies, `Command+Return` pastes.

**Quick AI and AI Chat**

- `Tab` turns the launcher into a chat; follow-ups stay in the thread and
  streamed answers can be stopped, retried, or regenerated.
- `Command+J` moves the chat into a complete, resizable window that shares one
  store of settings and history with the panel.
- Saved actions and assistants add custom instructions, tools, and context
  skills, with fuzzy slash aliases and hotkeys.
- Read-only tools cover local notes and tasks, project evidence, skills, and
  web search. Each tool switches on or off per chat.
- The Chief of Staff (`cos`) has a pinned conversation at the top of the AI
  Chat list: health in its status line, then DECIDE, TODAY, WAITING ON
  OTHERS, PROJECTS, LATER and FYI above the chat, or a Board (`⌥⌘2`). On a
  card, `⌘↩` Do it, `⌘E` Edit, `⌘L` Later, `⌘⌫` No, `⌘R` Bring back; `⌘N`
  adds a task. Its notifications come from Quick Launch. Type `cos` in the
  launcher to open it.

**Capture and screen**

- Screenshot attachments, a Screenshots catalog with on-device OCR, and Screen
  Awareness commands for the focused window, a screen area, or selected text.
- Text from screen, a colour picker, and a bounded local Clipboard History.
- Type to Click labels every clickable control in the frontmost app so you can
  click one by typing its name.

**Text and system tools**

- A Translator window for selected or typed text.
- Window management across halves, thirds, fourths, and displays.
- Caffeinate with timed sessions and Agent Watch.
- Emoji and symbols, and local Screen History search.

**Models and providers**

- Swappable local and hosted OpenAI-compatible providers, CLI subscription
  providers, and a provider that uses the installed pi configuration.
- Enable or disable individual models; API keys live in the macOS Keychain.

**Privacy**

- No analytics and no telemetry. Provider keys, chat history, and source blobs
  stay on this Mac and are owner-only.
- One bounded, content-free local review log can be inspected, exported, and
  cleared, or turned off entirely.

The full behavior reference is in [docs/features.md](docs/features.md).

## Requirements

- macOS 26 or later
- Apple Silicon
- Xcode command-line tools for source builds
- At least one inference provider: a local OpenAI-compatible server, a hosted
  API, or a CLI subscription, configured in **Settings › Models**

## Build and install

```bash
git clone https://github.com/tristan-mcinnis/quick-launch.git
cd quick-launch
swift test
make install
```

`make install` builds, signs, and copies the menu-bar app to
`/Applications/Quick Launch.app`. Run `make run` to open the installed app.
The install target refuses to build from a dirty working tree, so the installed
binary always traces to a commit; override deliberately with
`QL_ALLOW_DIRTY=1`.

Local builds use the stable designated requirement
`com.tristanmcinnis.quick-launch`, so macOS Accessibility approval survives code
changes. The generated `build` directory is excluded from Spotlight so it does
not appear as a second installation.

## Use

1. Press `Option+Space`.
2. Type an app name or a configured alias. Arrow keys and `Return` open the
   highlighted row.
3. Type a question, or a saved alias such as `/grammar`, `/tldr`, or
   `/search`.
4. Press `Tab` to ask Quick AI and keep the chat. Press `Escape` to stop a
   stream and keep the answer that arrived.
5. Type a follow-up in the composer. `Return` while an answer streams queues it
   until the answer ends.

`Command+Shift+V` opens Clipboard History directly. `Command+K` lists the
actions for the highlighted row. Escape steps back one layer at a time and
closes the launcher at root search. Open it again within the **Keep my place**
interval and it is where you left off.

## Documentation

- [docs/features.md](docs/features.md) — the full feature reference
- [docs/product-scope.md](docs/product-scope.md) — the product scope and
  interaction contract
- [CHANGELOG.md](CHANGELOG.md) — release history
- [docs/](docs/) — design notes, audits, and plans

## Privacy

Quick Launch keeps no analytics and sends nothing about your use anywhere. API
keys are stored in the macOS Keychain. Chat history, attachments, clipboard
history, snippets, and picks are local, owner-only, and bounded, and can be
cleared. A question sent to a cloud provider contains the question, the
permitted conversation context, the app's instruction, and any permitted tool
results; source-only questions do not silently widen. See
[docs/features.md](docs/features.md#privacy-boundary) for the details.

## Development

- Build and test from the repository root: `swift test`.
- Package a local build: `SIGN_IDENTITY=- ./scripts/build-app.sh`. The result is
  `build/Quick Launch.app`.
- Verify the packaged bundle's metadata after identity or packaging changes.
- The native rail focus proof takes the keyboard and runs separately:
  `QUICK_LAUNCH_NATIVE_FOCUS_PROOF=1 swift test --skip-build --filter PaletteRailFocusProofTests`.

The house Swift rule is `../design-system/SWIFT.md`. This repository is its
reference implementation, with a floor of macOS 26, swift-tools 6.2, and Swift
Testing.

## Acknowledgements

Quick Launch began as a fork of
[apfel-quick](https://github.com/Arthur-Ficial/apfel-quick) by Arthur Ficial.

The interface and behavior draw on earlier tools:

- [Raycast](https://www.raycast.com/) — the launcher surface, the Quick AI
  panel, the row action list, the footer hints, and the window-management set.
- [Shortcat](https://shortcat.app/) and [Homerow](https://homerow.app/) — the
  Type to Click approach of labelling and clicking controls through
  Accessibility.
- [Vimium](https://vimium.github.io/) — the equal-length, non-prefix hint style.
- [Tuna](https://tunaformac.com/) — the predecessor this app replaces. Its
  translator behavior is mirrored, and its snippets and quick links are
  imported once.

It depends on Apple's [swift-markdown](https://github.com/apple/swift-markdown)
and [swift-cmark](https://github.com/swiftlang/swift-cmark), both Apache-2.0.

## License

MIT. See [LICENSE](LICENSE).
