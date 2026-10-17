# Quick Launch — Project Contract

Canonical file. `AGENTS.md` is a symlink to this file so every runtime reads one contract.

## Product

Quick Launch is a free, open-source (MIT) macOS launcher and instant AI
action overlay. Keep it small, keyboard-first, fast, and focused on immediate actions.
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

- `origin`: `tristan-mcinnis/quick-launch`
- `upstream`: original `Arthur-Ficial/apfel-quick` project, retained for
  attribution and upstream comparison only
- When Tristan explicitly says **push to main** for this project, commit the
  requested project changes and push `origin/main`. Never push to `upstream`.
- Keep the original MIT copyright attribution and the README fork credit.

## Private Data and Secrets

Treat Git history as durable and public. Never commit API keys, tokens, passwords, private keys, personal
snippet exports, `.env` files, credentials, or local launcher data.

Provider API keys belong in macOS Keychain through `APIKeyStore`. Personal
snippets and Quicklinks belong in Quick Launch's owner-only Application Support
catalog; legacy Tuna items are imported once when available. Never copy their
values into this repository, settings, fixtures, logs, screenshots, or tests.
Preserve and extend `.gitignore` when introducing new local-data paths.
If a suspected secret appears in Git history, report the affected file and
credential type without echoing the value, then rotate the credential.

## Product Boundaries

AI Chat is one conversation window over the same providers and tools. No autonomy, no projects, no automations, no file changes; those belong to pi.

AI Chat is the House's general chat. RTI keeps its own standalone chats
because they are grounded in a meeting or a recording session (decided
2026-09-26); a chat that is not about a meeting belongs here.

Retired 2026-10-17: the Chief of Staff face (the pinned conversation, its
cards, notices and the `cos` CLI calls). House captures, makes recallable and
assists in the moment; synthesis and judging happen downstream in the vault
and Pi, so AI Chat is a plain chat window again. Old history may still hold
the pinned conversation (`QuickHistoryStore.retiredPinnedChatID`); it is
dropped on load and the file on disk is left alone. `UserNotificationRouter`
is the app's one notification delegate.

house-chat-core (its own repo, pinned by GitHub URL and tag in `Package.swift`) owns the shared chat policy, archival schema and
attachment interfaces consumed by Quick Launch and RTI. Keep it compatible
with Swift 6.0 and macOS 14. Histories and app defaults remain separate;
sharing an implementation must not create a global chat or settings owner.

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
designs. Quick Launch keeps no background screen history: its own Screen
History collector was retired on 2026-09-26 (Tristan's call in the House sweep), and
`screenctx` (`../memory-screenctx`) is the House's one screen-history
collector. Do not bring a collector back here. Explicit screen/window
capture for a chat is a separate action, not background capture. The old
local files (`screen-history.sqlite3*`, `Screen History Frames`, `Screen
History Soak`, `Screen History Coast Freeze`,
`screen-history-retirement-review.json` in Application Support, and the Coast
freeze integrity key, Keychain service
`ai.quick-launch.screen-history.coast-freeze`) are no longer read or written;
the app never deletes them.

**Chat retention and routing, approved 2026-09-17:** a submitted attachment
(document, image, screenshot, selection or fetched page) is retained with its
original bytes, extracted content, hashes and source metadata for follow-up.
Abandoned draft attachments are not retained. Local `chat-assets/` owns the
content-addressed bytes; structured conversation records reference them.
Retain saved chats and attachments until explicit deletion, not a count or
age threshold. Keep files owner-only and eligible for ordinary local backups;
do not add cloud sync, vault ingestion or Git copies. Delete only unreferenced
owned assets, never original source files. Existing legacy missing content
must stay labelled missing rather than being silently fetched again.

Screenshots may be sent directly to the selected cloud vision model, currently
DeepSeek by default. Record the effective destination on every answer, and
show it before Send when it is not routine: a blocked route, an on-Mac route,
or an image going somewhere other than the chosen model. The routine cloud
route the user already chose is not announced. Local capture or storage does
not mean local inference. The approved implementation contract is
`docs/chat-harmonization-plan-20260917.md`.

**Tools and grounding, amended 2026-09-20** (superseding the 2026-09-17
rule that source-only questions must not fetch memory, vault, web or
skills): every enabled tool is offered on every request, so the model
decides whether it needs one. A grounded turn says so in its system prompt
(`ChatContextGate.groundingDirective`) and its request still carries only
in-scope source text (`ChatContextPipeline.scopedMessages`); that, not a
withheld tool set, is what keeps a grounded answer on its source. There is
no Attached sources / Broader search control.

Clipboard History remains separate: it may retain the user's clipboard copy,
honours concealed/transient markers, stays owner-only and retains its existing
count/byte budgets. AI request attachments are never written to Clipboard
History.

## Development

- Build and test from the repository root.
- Run `swift test` for the full suite.
- Run `SIGN_IDENTITY=- ./scripts/build-app.sh` to verify local packaging.
- The built app is `build/Quick Launch.app`.
- `make install` installs `/Applications/Quick Launch.app`.
- `make dmg` is the free release path: ad hoc signed `QuickLaunch-<version>-macos-arm64.dmg`,
  `SHA256SUMS`, release notes and the draft-release command in `dist/release`
  (`scripts/make-dmg.sh`, checked by `scripts/verify-dmg.sh`). Tristan has no
  Developer ID, so this is the documented default; `scripts/release.sh` is the
  notarized path and needs one. Never run `gh release create` without his go.
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

Run `make test` after source changes: the publish scrub
(`scripts/scrub.sh`; client names live in the untracked `.scrub-private`),
`swift test`, and the HouseChatCore suite. The vault, memory and House server
names may appear only in `Sources/Services/HouseServer.swift` and
`docs/personal-setup.md`; Tristan's own wiring is described there. For packaging or identity changes, also
run `SIGN_IDENTITY=- ./scripts/build-app.sh` and verify the resulting
`build/Quick Launch.app` metadata.

`swift test` is the pre-push gate and must pass on a busy machine: a test
waits on the work itself (an injected clock such as `TypeToClickClock`, an
`AttachmentDeadline`, or a model's own tasks, as `TranslatorModel.settled()`),
never on a wall-clock budget. Speed budgets are opt-in and run on a quiet
machine: `QUICK_LAUNCH_PERF=1 swift test --filter LauncherPerformanceBudgetTests`.
Never push with `SKIP_TESTS=1`; a flaky gate is a bug to fix.

The native rail focus proof takes the keyboard and runs separately from other
window tests. After the main suite, run
`QUICK_LAUNCH_NATIVE_FOCUS_PROOF=1 swift test --skip-build --filter PaletteRailFocusProofTests`.
It checks action-search typing and Escape focus restoration, and writes dark
and light render proofs to `/tmp/quick-launch-render-proof/`.
