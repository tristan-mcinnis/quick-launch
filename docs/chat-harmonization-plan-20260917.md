# Approved House chat and launcher implementation

Approved by Tristan on 17 September 2026 after `cross-app-context-audit-20260917.md`. This document records the implementation contract, not a separate task registry. The full approved conversational plan is titled “Harmonize House chat behavior and restore launcher predictability.”

## Approved choices

- Cloud screenshot inference remains allowed. Label the destination before Send and on each answer.
- Keep all submitted attachments, including screenshots, original files, extracted text, selections and fetched-link snapshots, with structured metadata for follow-up. Do not persist abandoned drafts. No automatic pruning of saved chats or assets.
- Quick AI and AI Chat keep a shared Quick Launch history. RTI keeps its own history. A combined library is deferred exploration, not this release.
- Model selections are per chat, with separate app defaults. Freeze effective configuration per turn and record it.
- Preserve app-specific empty-Return actions: Quick AI Paste, AI Chat Copy, RTI configured action. Make the action clear.
- `/new` and `/clear` clear chat/draft/pending attachment context consistently without ending RTI recording. Preserve the old saved thread.
- Quick Launch learns `voice` → Voice Memos and supports Hide from Quick Launch with Settings → Items → Hidden restoration.

## Implementation scope

### Shared logic

Create `Packages/HouseChatCore`, Swift tools 6.0, macOS 14, in the Quick Launch repo. RTI consumes it. Small interfaces own context policy, command parsing, durable attachment/conversation storage, versioned turn metadata, extraction and location-aware context selection. App-specific windows, capture, credentials, providers, recording and root resolution stay in the apps. No daemon or new repository.

### Context and models

Explicit attachments and follow-up source material default to source-first. Disable memory/vault/web/skill loading in both offered tools and execution, including RTI pre-search, unless the question requests broader evidence or the user selects Broader search. Keep a visible Attached sources / Broader search control. Existing ordinary chat and meeting capabilities remain.

Freeze chosen/effective model and reasoning per turn. Fast explicitly disables thinking where supported; preserve user overrides and RTI Summary’s visible thinking override. Prefer selected image-capable model; an existing vision fallback must be visibly labelled. Missing credentials/capabilities block rather than silently switching provider. Do not migrate credential stores.

### Storage

Use owner-only, atomic, content-addressed local `Application Support/<app>/chat-assets/` storage with hash verification. Retain original bytes, inference-normalized images, extraction/OCR/location data and credential-free request snapshots. No eviction. No new cloud sync or automatic vault ingestion. Keep normal backup eligibility.

One structured record per conversation. Quick Launch migrates existing `chat-history.json` to `chats/<id>/conversation.json`; any index is rebuildable. RTI owns structured threads under its existing vault `personal/rti/chats/threads/`, with local asset references. Existing daily logs and meeting `chat.md` are compatibility projections linked by IDs. Preserve all threads during one recording.

Versioned records include conversation/turn IDs, timestamps/surface/status, parent/regeneration and RTI session/project links, selected/effective provider/model/reasoning, context references and hashes, prompt snapshot/version, attachment extraction/trim notices, selected chunks/citations, tools/arguments/results/status/adapter, and capture/preparation/persistence/first-token/tool/model-round/total timings plus usage when available.

Save submitted material before provider execution. Disk failure keeps the draft and blocks send. Checkpoint streams and label interrupted turns. Migrations are idempotent and verified before cutover, retaining rollback data. Never replace corrupt history with an empty store. Old missing bytes stay explicitly missing; no automatic reread/fetch.

Provide search, rename, pin, resume, export, confirmed deletion and storage usage. Delete owned records/projections and last-reference blobs, not original sources or meeting audio. Do not guess ownership of legacy logs. RTI adds Chats to its existing Sessions surface. Legacy daily entries remain dated turns; Open as New Chat does not invent prior chat boundaries.

### Composer

Built-in commands precede prompt aliases. Unknown slash commands stay local with an explicit Send as Text action. Unified searchable @/+ context chooser grammar with RTI-specific project/meeting additions. Preserve legacy quoted RTI mentions. Snapshot files on first send; Refresh creates a new version. Show readiness, limits, saved state and route. Keyboard/IME/chooser actions must not trigger empty-Return delivery accidentally.

### Retrieval and documents

Repair RTI’s stale Hermes CLI path with one current resolver, scope forwarding and validated output. Diagnose Quick Launch’s SSH vault failure independently; report if original cause cannot be reproduced. Surface available/no-match/degraded/unavailable separately and retain fallback diagnostics. Do not change the wider Neon architecture.

Share existing Quick Launch document formats and extraction safety with RTI. Retain up to 2 million extracted characters per file while keeping original bytes. Request ceilings remain 200,000 characters per attachment and 400,000 total, further reduced to model budget. Preserve ZIP/page/slide/sheet/row/OCR/time safety limits. Chunk around 2,000 characters with 200 overlap and structural locations; lexical English/CJK retrieval selects up to 12 chunks per attachment within total budget. Short sources whole, long broad summaries explicitly partial/distributed, no fabricated comprehensive coverage. No embeddings or workbook calculation engine.

### Launcher

Reuse learning storage/ranker. Verify successful Voice Memos selection ranks first for the same query after dismissal/restart, keyboard/mouse/action paths. No learning on highlight/cancel/failed launch. Preserve settings, decay and prior learning.

Add Hide from Quick Launch, distinct from Hide Windows. Extend existing item configuration with compatible hidden state and minimal identity/display metadata. Filter before ranking/caps/favourites in root and scopes, including aliases/pins. Keep explicit hotkeys working and learning/config intact. Hidden settings support search/type filter, Restore/Restore All, unavailable targets. No source deletion. Transient computed answers without stable IDs excluded.

## Delivery and acceptance

Implement in isolated stages with non-overlapping worker ownership. Fresh tests, independent review and installed build verification are required. Cover source-only zero-tool requests; broader opt-in; actual model routing; persistence after restart/original deletion; corrupt/disk-full/crash/migration cases; /new during stream/read/recording; long/CJK/Office/OCR/tail facts; retrieval failure distinctions; launcher learning and hidden restoration; keyboard/IME/minimum-size/dark/light renders.

Run fresh core/Quick Launch/RTI tests, design lint and packaging, not cached pre-HEAD bundles. Use synthetic content for any live provider checks. Native focus tests run separately. Do not interrupt active recording to install. Follow repository signing/release rules and verify installed commit stamps. Preserve rollback paths. No auto-push where repository/user authority does not permit it.

## Explicit exclusions

No merged history, credential consolidation, background crawl, expanded capture, new vector database, autonomous editing or spreadsheet calculation. Combined history is future exploration only.
