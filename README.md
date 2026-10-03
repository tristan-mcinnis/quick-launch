<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Quick Launch icon">
</p>

<h1 align="center">Quick Launch</h1>

<p align="center"><strong>A keyboard-first Mac launcher with an instant AI overlay.</strong></p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2026%2B%20%C2%B7%20Apple%20Silicon-1f2937">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-3b5bdb">
  <img alt="Free and open source" src="https://img.shields.io/badge/free-and%20open%20source-3b5bdb">
  <img alt="Runs locally" src="https://img.shields.io/badge/runs-locally-1f2937">
</p>

Press `Option+Space` and one search field opens over whatever you are doing.
Launch an app, run a command, move a window, translate a selection, or ask an
AI. `Tab` turns the panel into a chat, and `Command+J` moves that chat into a
full window. It is for people who live on the keyboard and want a launcher
whose inner workings they can read and change.

> **Free and open source.** Quick Launch is free to use, change and share under the MIT License.
> No account, no subscription, no telemetry. Nothing leaves your Mac unless you send it to an AI or web-search provider you chose; with a local model, nothing leaves at all.

## Features

**Launcher**

- One ranked search across apps, folders, commands, snippets, quick links,
  saved actions, and the Ask AI row.
- Fuzzy matching, per-item aliases, optional per-item global hotkeys, and
  learned ranking that fades over 14 days.
- Nested catalogs, keyboard-only navigation, and footers that show the keys
  that work right now.

**Instant answers, no model**

- Math, unit conversions, dates, and city times are computed on your Mac.
- Answers appear as you type. `Return` copies, `Command+Return` pastes.

**Quick AI and AI Chat**

- `Tab` turns the launcher into a chat. Follow-ups stay in the thread, and a
  streamed answer can be stopped, retried, or regenerated.
- `Command+J` moves the chat into a resizable window that shares one store of
  settings and history with the panel.
- Saved actions and assistants add custom instructions, tools, and context,
  with fuzzy slash aliases (`/grammar`, `/tldr`, `/search`) and hotkeys.
- Read-only tools: web search, plus skills, memory, tasks, and a project vault
  when those optional integrations are present. Each tool turns on or off per
  chat.
- Attachments: files, images, links, screenshots, and the current selection.

**Capture and screen**

- Screenshot attachments, a Screenshots catalog with on-device OCR, and
  commands for the focused window, a screen area, or selected text.
- Text from screen, a colour picker, and a bounded local Clipboard History.
- Type to Click labels every clickable control in the frontmost app, so you can
  click one by typing its name.

**Text and system tools**

- A Translator window for selected or typed text.
- Window management across halves, thirds, fourths, and displays.
- Caffeinate with timed sessions, and Agent Watch to keep the Mac awake while
  a coding agent works.
- Emoji and symbols, and system toggles such as Dark Mode and Empty Trash.

**Models and providers**

- Swappable providers: local OpenAI-compatible servers (LM Studio,
  [Local Models](https://github.com/tristan-mcinnis/local-models), and others),
  hosted OpenAI-compatible APIs, and CLI subscription providers.
- Turn single models on or off. API keys live in the macOS Keychain.

The full behaviour reference is [docs/features.md](docs/features.md).

### Optional integrations

These features appear only when their backing tool is on your Mac. Without
it, the feature hides itself or reports what is missing. Nothing else depends
on them.

| Integration | What it needs | Without it |
|---|---|---|
| Skills tool | Skill folders with a `SKILL.md` in `~/.claude/skills` | The tool is not offered. |
| Memory and Tasks tools, Capture to Memory | A `recall` CLI on `PATH` | The tools are not offered; Capture says recall is not installed. |
| Vault tool and Vault Search, SearXNG web search, page-reader fallback | An SSH host alias for your own server in `~/.ssh/config` (the "House server"; set its name with `defaults write com.tristanmcinnis.quick-launch HouseServerHost <alias>`) | The Vault tool is not offered, Vault Search says it is unavailable, Automatic web search uses the next backend, and pages are read directly. |
| Chief of Staff pinned chat | A `cos` CLI at `~/.local/bin/cos` (or `COS_BIN`) | The pinned chat does not appear. |
| Read aloud | [Local TTS](https://github.com/tristan-mcinnis/local-tts) running on `127.0.0.1:8081` | Says Local TTS is not running. |
| Continue in pi | `tmux` and `pi` on `PATH` | Settings shows what is missing. |

**Settings › General › Chat** shows which of these it found.

## Requirements

- macOS 26 or later on Apple Silicon.
- Xcode 26 or its command-line tools (Swift 6.2) to build from source.
- At least one AI provider for the chat features: a local OpenAI-compatible
  server, a hosted API key, or a CLI subscription. The launcher, math, and
  system tools need none.

## Install

### Download

Get the latest `QuickLaunch-<version>-macos-arm64.dmg` from
[GitHub Releases](https://github.com/tristan-mcinnis/quick-launch/releases/latest).
Open it and drag Quick Launch to Applications. It needs macOS 26 on Apple
Silicon. Each release lists a SHA256 you can check with `shasum -a 256 -c SHA256SUMS`.

#### First open (macOS will warn you)

Quick Launch is not notarized. It is a free project, and it has no paid Apple Developer ID. So macOS blocks the first open. Only open it if you downloaded it from the Releases page of this repository.

1. Open the DMG and drag Quick Launch to Applications.
2. Open Quick Launch once. macOS says it cannot verify the app. Click Done.
3. Open System Settings, then Privacy & Security. Scroll down and click Open Anyway next to Quick Launch. Confirm.

If you prefer Terminal, run this once, then open the app:

```bash
xattr -dr com.apple.quarantine "/Applications/Quick Launch.app"
```

Each release is signed ad hoc. So macOS may ask again for permissions such as Accessibility or Microphone after an update. Grant them again when asked.

### Build from source

```bash
git clone https://github.com/tristan-mcinnis/quick-launch.git
cd quick-launch
make test
make install
```

`make install` builds the app, signs it, and copies it to
`/Applications/Quick Launch.app`. `make run` opens it. It signs with your
Apple Development or Developer ID certificate when you have one, and ad hoc
when you do not. An ad hoc build gets a new signature on every rebuild, so
macOS asks again for Accessibility and the Keychain asks again for saved keys.

The install target refuses a dirty working tree, so the installed app always
traces to a commit. Override with `QL_ALLOW_DIRTY=1`.

### Package a release

`make dmg` builds the app with ad hoc signing and writes
`QuickLaunch-<version>-macos-arm64.dmg`, `SHA256SUMS`, `RELEASE_NOTES.md` and
the draft-release command to `dist/release` (set `RELEASE_OUT` to move it).
It checks the image without launching the app. It needs no Developer ID and
publishes nothing; the printed `gh release create ... --draft` command is the
only step left, and you run it yourself. The notarized path
(`scripts/release.sh`) stays available for a Developer ID holder.

### Permissions

macOS asks for these the first time a feature needs them:

| Permission | Used for |
|---|---|
| Accessibility | Reading and replacing selected text, Type to Click, window management. |
| Screen Recording | Screenshots, text from screen, and screen-aware commands. |
| Automation (System Events, Finder) | System toggles such as Dark Mode, Lock Screen, Empty Trash, and Eject. |
| Notifications | Answer notices from AI Chat, and Chief of Staff notices when that integration is present. |

## Usage

1. Press `Option+Space`.
2. Type an app name or an alias. Arrow keys and `Return` open the highlighted
   row.
3. Type a question, or a saved alias such as `/grammar`, `/tldr`, or
   `/search`.
4. Press `Tab` to ask Quick AI and keep the chat. Press `Escape` to stop a
   stream and keep the answer that arrived.
5. Type a follow-up. `Return` while an answer streams queues it until the
   answer ends.

`Command+Shift+V` opens Clipboard History. `Command+K` lists the actions for
the highlighted row. Escape steps back one layer at a time and closes the
launcher at root search. Open it again within the **Keep my place** interval
and it is where you left off.

Pick providers and models in **Settings › Models**. The global hotkey, in-app
keys, aliases, catalogs, and providers are all yours to change.

## Privacy

- **Read:** the text you type, the selection when you run an action on it, the
  screen only when you run a screen command, and the clipboard for Clipboard
  History.
- **Sent:** a question to a cloud provider carries the question, the allowed
  conversation context, the app's instruction, any attachments you added, and
  any permitted tool results. A web search sends the query to the backend you
  chose. A local provider keeps everything on your Mac.
- **Stored:** API keys in the macOS Keychain. Chat history, attachments,
  clipboard history, snippets, and launcher picks stay in owner-only files in
  Application Support, bounded, and clearable. No analytics. One local,
  content-free review log can be inspected, exported, cleared, or turned off.

The details are in [docs/features.md](docs/features.md#privacy-boundary).

## Build from source

```bash
make test                              # scrub gate, app tests, HouseChatCore tests
swift build -c release                 # release build
SIGN_IDENTITY=- ./scripts/build-app.sh # package build/Quick Launch.app
make dmg                               # ad hoc DMG + SHA256SUMS + release notes
```

- `make test` runs `scripts/scrub.sh` (no personal paths or keys in tracked
  files), `swift test`, and `swift test --package-path Packages/HouseChatCore`.
- The native rail focus proof takes the keyboard and runs on its own:
  `QUICK_LAUNCH_NATIVE_FOCUS_PROOF=1 swift test --skip-build --filter PaletteRailFocusProofTests`.
- Speed budgets run only on a quiet machine:
  `QUICK_LAUNCH_PERF=1 swift test --filter LauncherPerformanceBudgetTests`.
- `Packages/HouseChatCore` is the shared chat core (schema, archives,
  retrieval policy, slash commands). Quick Launch builds it from this repo.
- The only network fetch during a build is swift-markdown and swift-cmark
  from GitHub.

[CHANGELOG.md](CHANGELOG.md) has the release history, and [docs/](docs/)
holds design notes, audits, and plans.

## Part of House

Quick Launch is one of a small family of free, local-first Mac tools that share one design system.

| App | What it does |
|---|---|
| **[Quick Launch](https://github.com/tristan-mcinnis/quick-launch)** | Keyboard-first launcher and instant AI overlay. |
| [Local Dictation](https://github.com/tristan-mcinnis/local-dictation) | Hold a key, talk, and on-device text lands at your cursor. |
| [Local TTS](https://github.com/tristan-mcinnis/local-tts) | Fast on-device voice cloning and text-to-speech. |
| [Local Models](https://github.com/tristan-mcinnis/local-models) | One local daemon that serves a fleet of small models to every app. |
| [Usage](https://github.com/tristan-mcinnis/usage-menubar) | One menu-bar gauge for every AI subscription and API key. |
| [RTI](https://github.com/tristan-mcinnis/rti) | Meeting recorder with live transcription and a real-time copilot. |

## Credits

Quick Launch began as a fork of
**[apfel-quick](https://github.com/Arthur-Ficial/apfel-quick) by Arthur Ficial**.
His project gave Quick Launch its start: the menu-bar app, the hotkey
overlay, local math, the streaming client, the test suite, and the release
tooling and landing page. His copyright stays in
[LICENSE](LICENSE). Thank you, Arthur.

It is built on Apple's
[swift-markdown](https://github.com/apple/swift-markdown) (Apache-2.0) and
[swift-cmark](https://github.com/swiftlang/swift-cmark), the cmark-gfm parser
by John MacFarlane, GitHub and others (BSD-2-Clause). Emoji names come from
the Unicode Character Database.

The interface draws on earlier tools. No code from them is included.

- [Raycast](https://www.raycast.com/): the launcher surface, the Quick AI
  panel, the row action list, the footer hints, and the window-management set.
- [Shortcat](https://shortcat.app/) and [Homerow](https://homerow.app/): Type
  to Click, labelling and clicking controls through Accessibility.
- [Vimium](https://vimium.github.io/): the equal-length, non-prefix hint style.
- [Tuna](https://tunaformac.com/): the predecessor this app replaces. Its
  translator behaviour is mirrored, and its snippets and quick links are
  imported once.

Full licence texts are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md),
which also ships inside the app.

## License

MIT. See [LICENSE](LICENSE). Copyright (c) 2026 Arthur Ficial and
Copyright (c) 2026 Tristan McInnis.
