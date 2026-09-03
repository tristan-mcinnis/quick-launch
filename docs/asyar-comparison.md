# Asyar vs Quick Launch (2026-08-27)

Repo: https://github.com/Xoshbin/asyar (GPL-3.0, 542 stars, 34 forks, started Feb 2025, pushed 2026-08-26, very active). Tagline: "The power of Raycast. The speed of Alfred. Privacy by design."

## What Asyar is

A full cross-platform Raycast competitor (macOS, Windows, Linux) built on Tauri + Rust + Svelte 5. It is a *platform*: app launcher, file search with a Rust-native index, extension store with sandboxed-iframe extensions, an AI-agent extension builder, MCP client with bundled `bun`/`uv`, AI agents with tool calling and persistent threads, scripts with metadata headers, snippets with background expansion, clipboard history, window management (17 presets), calculator with currency conversion, themes, deep links (`asyar://`), background scheduling, HUD notifications, and optional end-to-end-encrypted cloud sync (Argon2id + AES-256-GCM).

## What Quick Launch is

A single-user, native Swift, macOS-only AI action overlay. ~33.6k lines across ~110 source files. Deliberately scope-fenced by the golden goal: instant prompt-to-result, not a launcher platform. No extensions, no telemetry, Keychain secrets, direct process execution with no shell interpolation, protocol-backed services with tests.

## Feature overlap (independently converged)

| Capability | Asyar | Quick Launch |
|---|---|---|
| Global hotkey overlay | Yes (12 ms median to window) | Yes (GlobalHotKey) |
| Streaming AI, provider choice | OpenAI/Anthropic/Google/Ollama/OpenRouter/any OpenAI-compat | Local OpenAI-compat servers, API providers, one-shot CLI subscriptions |
| Clipboard history honouring concealed/transient NSPasteboard flags | Yes | Yes (commit 0dafcbf, same markers) |
| Inline calculator | Yes, plus currency | Yes (MathCalculator + LocalConversionResolver) |
| Snippets / quicklinks | Yes, background expansion | Yes (Tuna catalog, preview pane) |
| Window layouts | 17 presets + saved layouts + undo | WindowLayout / WindowManager, deterministic previous-window layouts |
| Markdown/LaTeX/code render of AI output | Yes | Markdown yes (MarkdownRenderer); no LaTeX/Mermaid |
| Web search from the bar | Portals / context modes | Model-driven web search tool + SearXNG service |
| Emoji | Not called out | EmojiCatalog with tones |
| Colour tools | No | Colors catalog + screen colour picker |
| Screen capture history | No | ScreenHistory* pipeline (capture, OCR index, vault save, retirement) |
| Vault search | No | VaultSearchService |
| Caffeinate control | No | Native CaffeinateManager |
| Extensions / MCP / agents | Core feature | Deliberately excluded |

## The two design bets

**Asyar bets on breadth via a web stack.** Its own benchmark table is honest about the cost: 435.6 MB idle RAM and 3.20 % idle CPU, both *worse than Raycast* (272.6 MB, 0.04 %). It wins hotkey-to-window latency (12 ms vs 21.7 ms) and disk size. A Tauri shell plus extension iframes plus bundled bun/uv is heavy at rest.

**Quick Launch bets on depth via native Swift.** No Chromium, no V8, no extension host. The golden goal explicitly refuses the platform play (extensions, agents, ambient automation) until a separate permission/safety design exists. Your idle footprint is a fraction of theirs, and there is no sandboxing problem because there is no third-party code.

## Decision (Tristan, 2026-08-27)

Take nothing from asyar. No redaction layer, no denylist, no silent commands, no HUD. Quick Launch keeps its own path. This document is reference only.

## Bottom line

Asyar is what Quick Launch would become if it accepted the platform trade: broader, cross-platform, extensible, and ~10x heavier at idle. The two projects independently arrived at the same clipboard-privacy design (concealed/transient pasteboard markers), which validates yours. Nothing else transfers.
