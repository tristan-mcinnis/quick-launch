# Quick Launch — Claude Instructions

Read and follow `AGENTS.md`; it is the canonical shared project contract. The
rules below summarize the product goal for Claude-specific sessions.

## The Golden Goal

Quick Launch is an instant AI action overlay for macOS. Press a global hotkey,
type a prompt or saved action, choose a model when needed, press Return, and
copy the streamed result. Keep the overlay small and fast. Apple on-device AI
is not used. Local OpenAI-compatible servers,
API providers, and one-shot CLI subscriptions can be swapped without turning
the app into a broad chat or agent workspace. Short follow-ups and bounded
local history support the immediate action. Finder automation, document
workflows, and autonomous file changes are outside the core until they have a
separate permission and safety design. The only screen capture is the owned
Screen History capture: opt-in, off by default, switched on in its own Settings
tab, local only, and hard-locked in the current build until its privacy review
passes. Explicit
clipboard-image attachments may be routed to the local vision server, but must
not be persisted. Preserve the local
math shortcut, no telemetry, Keychain secrets, direct process execution with
no shell interpolation, protocol-backed services with tests, deterministic
previous-window layouts, and native Caffeinate lifecycle control.

## Repository and Privacy

The working repository is the private `tristan-mcinnis/quick-launch` GitHub
repository. When Tristan explicitly says **push to main**, push `origin/main`,
never `upstream`. The `Arthur-Ficial/apfel-quick` upstream remains only for
attribution and comparison.

Never place personal snippets, Quick Link values, API keys, tokens, passwords,
private keys, `.env` files, credentials, or local launcher data in source,
tests, fixtures, screenshots, logs, commits, or Git history. API keys belong in
macOS Keychain, and Tuna content must remain in its external live stores.

The user-facing product name is always **Quick Launch**. The `apfel` engine
and Apple on-device provider were removed on 2026-08-22; `apfel` now appears
only in upstream attribution, the legacy Keychain service name, and history.

## Concurrency

One rule. A service that owns I/O (files, SQLite, Keychain, child processes,
the network) is an `actor`. State the UI reads is a `@MainActor final class`.
A `@MainActor` store that hands its disk work to `JSONFileStore` (clipboard,
color, launcher usage, chat history) satisfies the rule: the file store
serialises the I/O off the main thread. `@unchecked Sendable` needs a comment
on the type naming what guards the state; a type whose stored properties are
all `Sendable` takes plain `Sendable`. View models reach AppKit singletons
only through the seams in `Sources/Protocols/SystemServicing.swift`.

## Verification

Run `swift test` after source changes. For packaging or identity changes, also
run `SIGN_IDENTITY=- ./scripts/build-app.sh` and verify the resulting
`build/Quick Launch.app` metadata.
