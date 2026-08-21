# Quick Launch

**A lightweight, Spotlight-style AI action overlay for macOS.**

The focused launcher scope is documented in [docs/product-scope.md](docs/product-scope.md).

Press `Option+Space`, type a prompt or saved action, choose a model when you
want, and press `Return`. The reply streams into the overlay and is copied to
the clipboard. It remains an action tool, not a full chat workspace.

Quick Launch keeps the original Apple on-device path and adds swappable local,
API, and subscription-backed models. It was forked from the original
`apfel-quick` project.

## Core features

- Global, configurable hotkey and small floating panel
- Fuzzy application launcher with live rows, aliases, optional per-app hotkeys, arrow navigation, and Return to open
- Finder indexing through the macOS CoreServices application catalog
- Live Tuna Snippets and Quick Links, with aliases and optional per-item global hotkeys
- Screenshot attachments from the clipboard, routed automatically to a local MLX vision model
- Local, bounded, clearable text clipboard history on `Command+Shift+V`
- Opens on the display that contains the mouse pointer
- Previous-window management for left/right/top/bottom halves, thirds, and fourths
- Native Caffeinate toggle that keeps the Mac awake while Quick Launch is running
- Two-control overlay toolbar: Send and one menu for actions, models, history, and settings
- Direct SearXNG web search for explicit searches and time-sensitive questions
- Provider and model switcher inside the compact overlay menu
- Apple on-device model through the bundled `apfel` engine, when available
- Any OpenAI-compatible endpoint through a custom base URL
- Built-in setup for LM Studio, DeepSeek, Moonshot/Kimi, and OpenAI
- Local LM Studio model detection by scanning `~/.lmstudio/models`, without running `lms` or starting its server
- One-shot Claude Code subscription provider through the installed `claude` CLI
- Pi provider that uses Pi's configured models, extensions, skills, and custom tools
- `/search` retrieval through the existing SSH connection to SearXNG
- Selected-text actions that can show a result or replace the original text
- Command-K keyboard action picker with Paste, Copy, and Copy & Paste, plus fuzzy slash aliases such as `/eml`
- Editable action names, prompts, aliases, output behavior, provider, model, and global hotkey
- Short follow-up threads and a local, bounded recent-history menu
- On-demand conversation transcript plus Copy Result and Paste Back actions
- Adjustable 10-second quick-reopen window for the last result or draft
- API keys stored in the macOS Keychain and not synced through iCloud
- Deterministic local math shortcut and optional automatic clipboard copy
- No telemetry

## Requirements

- macOS 26 or later
- Apple Silicon
- Xcode command-line tools for source builds

The Apple Foundation Model is optional in this version. Select LM Studio, Pi,
Claude Code, or an API provider if Apple Intelligence is unavailable.

Optional integrations must already be installed and signed in:

| Provider | Requirement |
|---|---|
| LM Studio | LM Studio. Start its local server before inference. Model discovery scans its model folder without opening the app. |
| Claude Code | `claude` on `PATH` and an active Claude Code sign-in. |
| Pi | `pi` on `PATH` with the desired providers, models, skills, and extensions configured. |
| API providers | A compatible endpoint and, when required, an API key. |
| Web search | SSH access to the existing `vault-vps` SearXNG service. |

Superwhisper's private S1 Mini file is not called directly. Superwhisper does
not expose that model as a general inference endpoint. A GGUF model can be
used after it is imported into a compatible server such as LM Studio.

## Build and run

```bash
git clone https://github.com/tristan-mcinnis/quick-launch.git
cd quick-launch
swift test
make install
```

`make install` builds, signs, and copies the menu-bar app to
`/Applications/Quick Launch.app`. Run `make run` to open the installed app.

The build script bundles `apfel` when it is available. A local app can still be
built without it. Source builds that need the Apple provider require `apfel`
on `PATH`:

```bash
brew install Arthur-Ficial/tap/apfel
```

## Use

1. Press `Option+Space`.
2. Type an app name or configured alias such as `spot`. The app list narrows with each key. Use the arrow keys and press `Return` to open the selected app.
3. Type a prompt or an action such as `/grammar`, `/tldr`, or `/search`.
4. Press `Return`. Press the stop button to cancel. Use the trailing menu for actions, models, history, and settings.
5. Type another prompt for a follow-up. The input regains focus when output finishes.

The panel opens with a 90 ms fade and closes immediately. Reduced Motion
disables the fade. Press Escape and
open it again within 10 seconds to keep the current result or draft. Change
that interval in **Settings → General**. A small footer under each completed
reply can copy the result or paste it into the previous app. Both controls have
44-point targets. Use `Command+Shift+C` to copy and `Command+Return` to paste
back. The trailing menu can show the current conversation.

Press `Command+Shift+V` to open Clipboard History directly. Use the arrow keys
and `Return` to paste the selected item into the previous app. Use `Command+C`
to copy the selected item. Clipboard History stores text only, is bounded to 50
items by default, and can be disabled or cleared in **Settings → Catalogs**.

The main launcher also contains Snippets and Quick Links. These catalogs read
the existing Tuna stores live. Highlight an item and press `Command+K` to give
it a search alias or global hotkey, or use the keyboard action pane to Paste,
Copy, or Copy & Paste. Paste targets the topmost external window directly
behind Quick Launch. Quick Launch does not duplicate snippet or link values
into its settings.

Copy a screenshot before opening Quick Launch and it appears as a removable
attachment. Submitting it routes the prompt and image to the local MLX vision
server at `127.0.0.1:8080`; an empty prompt asks for a useful description.
Screenshot bytes are kept only for the current request and are not written to
history or settings.

Type a layout name such as `left half`, `center third`, or `third fourth` and
press Return to resize the window that was active immediately before Quick
Launch. Open the highlighted command with `Command+K` to assign a shorter alias
or global hotkey. The Commands catalog contains all halves, thirds, fourths,
and the Caffeinate toggle. Caffeinate can also be toggled by right-clicking the
Quick Launch menu-bar icon.

Select text in another app before opening Quick Launch, then press `Command-K`
to choose an action. The default Clean Up and Translate actions replace the
selection. Summarize opens the result for follow-up. `Control+Option+S` runs
Summarize directly. macOS asks for Accessibility access the first time a
selected-text action needs it.

Slash aliases are fuzzy. `/eml` finds `/email`. Press `Tab` to complete the
alias or `Return` to run the best match.

Pure math such as `sqrt(2)^2` bypasses every model and runs locally. Common date, time, day, and time-zone questions also use trusted macOS data instead of a model.

## Configure models

Open **Settings → Models**.

- Select a built-in provider and refresh its model list.
- Add an endpoint for LM Studio alternatives, MLX servers, Ollama-compatible
  gateways, or any other server that implements OpenAI Chat Completions.
- Enter its base URL, model ID, and optional API key.
- Edit the global quick-action instruction.

API keys go to a non-synchronizing Keychain item. Provider settings, model
choices, actions, and bounded history contents use local `UserDefaults`.

For a saved action, open **Settings → Prompts**. Set its name, fuzzy alias,
prompt, output behavior, optional global hotkey, and optional provider and
model. An unpinned action uses the overlay's current model. Use `{selection}`
inside the prompt to control where selected or typed text is inserted.

`Command+,`, the menu-bar Settings item, and the overlay Settings action all
open the same settings interface. The main launcher shortcut is editable in
**Settings → General**. A shortcut
already owned by macOS, such as the default Spotlight `Command+Space`, shows a
conflict message instead of failing silently.

Open **Settings → Apps** to give any installed app a search alias and optional
global hotkey. You can also highlight an app in the overlay and press
`Command+K` to open its action pane, then edit the same alias and hotkey there.
Finder is included as an app through `/System/Library/CoreServices`.

Open **Settings → Catalogs** to reload the Tuna Snippets and Quick Links, edit
their aliases and global hotkeys, and configure or clear Clipboard History.

## Web search and Pi skills

The `/search` action and time-sensitive questions use the existing SearXNG
service over its warm SSH connection. Quick search sends only five ranked
titles, links, and short snippets to the selected model. It does not fetch full
pages. The source bundle is bounded and marked as untrusted external data.

The Pi provider still runs a fresh one-shot `pi` process for prompts that need
Pi extensions, skills, prompt templates, or custom tools. It disables Pi's
built-in raw file tools for the quick overlay.

MCP configuration in Quick Launch applies only to the managed `apfel` route.
Pi can use the tools and skills in its own configuration. General
OpenAI-compatible providers do not yet have a universal tool-calling loop.

## Privacy boundary

- Math and LM Studio stay local.
- Clipboard screenshots are sent only to the configured local MLX vision server
  at `127.0.0.1:8080` and are not persisted by Quick Launch.
- Apple inference stays local when the Apple provider is available.
- API and CLI subscription providers can send prompts to their configured service.
- Recent history is local, optional, and limited to 20 threads by default.
- Text clipboard history is local, optional, deduplicated, and bounded. It is
  stored in `~/Library/Application Support/Quick Launch/clipboard-history.json`.
- Tuna snippet and Quick Link values are read at runtime and are not logged or
  copied into Quick Launch settings.
- Selected-text actions use macOS Accessibility only to read or replace the
  current selection. They do not record the screen.
- The app has no telemetry.

## Architecture

```text
OverlayView
  → QuickViewModel
      → cached local application catalogue, including Finder
      → live Tuna snippet and Quick Link catalogues
      → bounded local text clipboard history
      → bounded SearXNG snippet bundle
      → managed apfel service
      → OpenAI-compatible SSE service
      → one-shot CLI service (Claude Code or Pi)

QuickSettings
  → provider and model catalogue
  → shared launcher-item aliases and hotkeys
  → saved action routes, aliases, output behavior, and hotkeys
  → bounded follow-up settings

SelectedTextService
  → focused selection through macOS Accessibility
  → direct replacement with a paste fallback

Keychain
  → provider API keys
```

The implementation uses SwiftUI, AppKit, `URLSession`, `Process`, and the macOS
Security framework. CLI prompts are sent over standard input. They are never
interpolated into a shell command.

## Performance contract

- The app catalogue is read once at launch. Typing never scans the file system.
- The panel resizes from state changes. Clipboard History uses one lightweight
  pasteboard change-count check per second when enabled. No other idle poll runs.
- Provider startup, model discovery, update checks, and web requests run only
  after an explicit action.
- App discovery and 100 fuzzy filters each have a 250 ms regression gate.
- Quick web search uses snippets rather than full-page extraction and has an
  eight-second retrieval ceiling.
- A silent web-answer model is stopped after 15 seconds. Linked results appear
  instead of an endless spinner.

## Deliberately not in the core build

Finder file actions, document attachments, ambient screen capture, screenshot
library management, the full Tuna translation window, voice input, and a larger
chat workspace are deferred. Explicit clipboard image
attachments are supported; Quick Launch does not observe or record the screen.

## License

MIT. See [LICENSE](LICENSE).
