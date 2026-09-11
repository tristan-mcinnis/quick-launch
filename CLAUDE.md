# Quick Launch — Project Contract

Canonical file. `AGENTS.md` is a symlink to this file so every runtime reads one contract.

## Product

Quick Launch is a private, personal macOS launcher and instant AI action
overlay. Keep it small, keyboard-first, fast, and focused on immediate actions.
It is not a general chat workspace or an autonomous desktop agent.

The product name is always **Quick Launch** in user-facing copy. Technical
identifiers are:

- Swift package and module: `QuickLaunch`
- App bundle: `Quick Launch.app`
- Executable and release slug: `quick-launch`
- Bundle identifier: `com.tristanmcinnis.quick-launch`

`apfel` was the upstream inference engine. It was removed on 2026-08-22 and
must not come back as a dependency or helper process. The name survives only
in upstream attribution, the legacy Keychain service (`APIKeyStore`), and the
changelog. The OpenAI-compatible client is `OpenAICompatibleService`.

## Repository

- `origin`: private repository `tristan-mcinnis/quick-launch`
- `upstream`: original `Arthur-Ficial/apfel-quick` project, retained for
  attribution and upstream comparison only
- When Tristan explicitly says **push to main** for this project, commit the
  requested project changes and push `origin/main`. Never push to `upstream`.
- Keep the original MIT copyright attribution and the README fork credit.

## Private Data and Secrets

This is a private repository, but treat Git history as durable and potentially
exposed. Never commit API keys, tokens, passwords, private keys, personal
snippet exports, `.env` files, credentials, or local launcher data.

Provider API keys belong in macOS Keychain through `APIKeyStore`. Personal Tuna
snippets and Quick Links are read live from their external stores; do not copy
their values into this repository, settings, fixtures, logs, screenshots, or
tests. Preserve and extend `.gitignore` when introducing new local-data paths.
If a suspected secret appears in Git history, report the affected file and
credential type without echoing the value, then rotate the credential.

## Product Boundaries

AI Chat is one conversation window over the same providers and tools. No autonomy, no projects, no automations, no file changes; those belong to pi.

Preserve:

- the configurable global launcher hotkey;
- local deterministic math;
- swappable local, API, and CLI-backed providers;
- short follow-ups and bounded local history;
- Keychain-backed secrets and no telemetry;
- direct process execution without shell interpolation;
- protocol-backed services with regression tests;
- deterministic previous-window layouts and native Caffeinate lifecycle control.

Finder automation, document workflows, and autonomous file changes remain
outside the core until they have explicit interaction, permission, and safety
designs. Screen capture exists only as the owned Screen History capture: opt-in,
off by default, enabled by "Enable owned screen capture" in its own Settings
tab, local only, and hard-locked in the current build until its privacy review
and soak test pass. A user-copied screenshot attached to an AI request is
ephemeral: it is routed locally and never persisted in settings or conversation
history. Attachment text is held in memory for the session only; chat history
keeps a reference (name, kind, size, hash, path or URL), never the text. The
single local exception is the Clipboard History, which may keep the
user's copy (text, image, rich text, or a file URL) on this Mac so it can be
restored later; it honours concealed/transient pasteboard markers, stays
owner-only, and is bounded by the history limit plus a total-byte budget. AI
request attachments are never written to the Clipboard History.

## Development

- Build and test from the repository root.
- Run `swift test` for the full suite.
- Run `SIGN_IDENTITY=- ./scripts/build-app.sh` to verify local packaging.
- The built app is `build/Quick Launch.app`.
- `make install` installs `/Applications/Quick Launch.app`.
- Keep UI labels, bundle metadata, scripts, release artifacts, documentation,
  tests, and website metadata consistent when changing product identity.
- Do not remove or overwrite unrelated user changes in a dirty worktree.

## Swift rule

The house rule is `../design-system/SWIFT.md`; this repo is its reference
implementation (floor **macOS 26, swift-tools 6.2, Swift Testing**). Local
application: a `@MainActor` store that hands its disk work to `JSONFileStore`
(clipboard, color, launcher usage, chat history) satisfies the actor rule, since
the file store serialises the I/O off the main thread. View models reach AppKit
singletons only through the seams in `Sources/Protocols/SystemServicing.swift`.

## Verification

Run `swift test` after source changes. For packaging or identity changes, also
run `SIGN_IDENTITY=- ./scripts/build-app.sh` and verify the resulting
`build/Quick Launch.app` metadata.
