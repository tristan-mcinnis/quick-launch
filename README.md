# apfel-quick

**A lightweight, Spotlight-style AI action overlay for macOS.**

Press `Option+Space`, type a prompt or saved action, choose a model when you
want, and press `Return`. The reply streams into the overlay and is copied to
the clipboard. It remains an action tool, not a full chat workspace.

This fork keeps the original Apple on-device path and adds swappable local,
API, and subscription-backed models. It is based on
[Arthur-Ficial/apfel-quick](https://github.com/Arthur-Ficial/apfel-quick).

## Core features

- Global, configurable hotkey and small floating panel
- Provider and model switcher inside the overlay
- Apple on-device model through the bundled `apfel` engine, when available
- Any OpenAI-compatible endpoint through a custom base URL
- Built-in setup for LM Studio, DeepSeek, Moonshot/Kimi, and OpenAI
- Local LM Studio model detection through `lms`, without starting its server
- One-shot Claude Code subscription provider through the installed `claude` CLI
- Pi provider that uses Pi's configured models, extensions, skills, and custom tools
- `/search` quick action pinned to Pi by default
- Editable saved actions, with optional per-action provider and model routing
- Short follow-up threads and a local, bounded recent-history menu
- API keys stored in the macOS Keychain and not synced through iCloud
- Deterministic local math shortcut and optional automatic clipboard copy
- No telemetry

## Requirements

- macOS 26 or later
- Apple Silicon
- Xcode command-line tools for source builds

The Apple Foundation Model is optional in this fork. Select LM Studio, Pi,
Claude Code, or an API provider if Apple Intelligence is unavailable.

Optional integrations must already be installed and signed in:

| Provider | Requirement |
|---|---|
| LM Studio | LM Studio plus its `lms` command. Start the local server before inference. |
| Claude Code | `claude` on `PATH` and an active Claude Code sign-in. |
| Pi | `pi` on `PATH` with the desired providers, models, skills, and extensions configured. |
| API providers | A compatible endpoint and, when required, an API key. |

Superwhisper's private S1 Mini file is not called directly. Superwhisper does
not expose that model as a general inference endpoint. A GGUF model can be
used after it is imported into a compatible server such as LM Studio.

## Build and run

```bash
git clone https://github.com/tristan-mcinnis/apfel-quick.git
cd apfel-quick
swift test
make install
```

The build script bundles `apfel` when it is available. A local app can still be
built without it. Source builds that need the Apple provider require `apfel`
on `PATH`:

```bash
brew install Arthur-Ficial/tap/apfel
```

## Use

1. Press `Option+Space`.
2. Choose a model from the CPU menu, or keep the current choice.
3. Type a prompt. Use actions such as `/grammar`, `/tldr`, or `/search`.
4. Press `Return`. Press the stop button to cancel.
5. Type another prompt for a follow-up, or use the history menu to start fresh.

Pure math such as `sqrt(2)^2` bypasses every model and runs locally.

## Configure models

Open **Settings → Models**.

- Select a built-in provider and refresh its model list.
- Add an endpoint for LM Studio alternatives, MLX servers, Ollama-compatible
  gateways, or any other server that implements OpenAI Chat Completions.
- Enter its base URL, model ID, and optional API key.
- Edit the global quick-action instruction.

API keys go to a non-synchronizing Keychain item. Provider settings, model
choices, actions, and bounded history contents use local `UserDefaults`.

For a saved action, open **Settings → Prompts** and optionally pin the action
to one provider and model. An unpinned action uses the overlay's current model.

## Pi search and skills

The Pi provider runs a fresh one-shot `pi` process. It keeps Pi extensions,
skills, prompt templates, and custom tools. It disables Pi's built-in raw file
tools for the quick overlay. The `/search` action uses this route, so it can use
the search tools already configured in Pi without turning apfel-quick into an
agent workspace.

## Privacy boundary

- Math and LM Studio stay local.
- Apple inference stays local when the Apple provider is available.
- API and CLI subscription providers can send prompts to their configured service.
- Recent history is local, optional, and limited to 20 threads by default.
- The app has no telemetry.

## Architecture

```text
OverlayView
  → QuickViewModel
      → managed apfel service
      → OpenAI-compatible SSE service
      → one-shot CLI service (Claude Code or Pi)

QuickSettings
  → provider and model catalogue
  → saved action routes
  → bounded follow-up settings

Keychain
  → provider API keys
```

The implementation uses SwiftUI, AppKit, `URLSession`, `Process`, and the macOS
Security framework. CLI prompts are sent over standard input. They are never
interpolated into a shell command.

## Deliberately not in the core build

Finder file actions, document attachments, selection replacement, screen
context, voice input, and a larger chat workspace are deferred. They need a
separate permission and safety design.

## License

MIT. See [LICENSE](LICENSE).
