# RTI, AI Chat and Quick AI: context audit

17 September 2026. Audit only. No application code, settings or installed builds changed.

## Finding

Quick AI spent this screen question consulting old conversations and a failing vault search. RTI answered from the attached screen without retrieval. All three saved turns name `deepseek-flash`. The main difference in this example is what the apps let the model do with the question, rather than which model they selected.

Quick AI and AI Chat already share a chat engine and history store. RTI has a separate engine, command grammar, context policy and archive. Shared styling has not made their behavior consistent.

The most urgent gaps are unnecessary retrieval on explicit-source questions, contradictory screenshot privacy documentation, an unavailable RTI semantic-search integration, and different meanings of new chat and attached context.

## Evidence and limits

Checked the three supplied Desktop screenshots, current source, safe saved settings, installed build metadata, and only the saved turns matching this screen question. Installed Quick Launch is `d626aec`, version 1.5.0. Installed RTI is `0c30202`, build `202609171107`. Both match their repository HEAD at audit time; both working trees started clean.

No new cloud request, screen capture or live UI interaction was performed. The screenshots were taken sequentially and the underlying captured pixels are not retained in Quick Launch history. This is an investigation of the recorded example, not a controlled speed benchmark or a fresh end-to-end acceptance test.

| Surface | Saved input and context | Retrieval recorded | Available timing |
|---|---|---|---|
| Quick AI | `what is this?`, context app Ghostty, screenshot 2560 × 1662; fresh chat | Memory: no hits; vault search failed; memory: 8 hits | 8.592 s from chat creation to last update |
| RTI | `what is this?`, screen attached, Meeting mode; no live session or transcript | No tools; no sources | 2.152 s logged total; 1.196 s to first token |
| AI Chat | `what is this?`, context app RTI Personal, screenshot 2560 × 1662; fresh chat | No tool records | 4.555 s from chat creation to last update |

The Quick Launch intervals are proxies for its request phase, not instrumented end-to-end latency. Capture and preparation precede chat creation. RTI's timing starts inside its send path, not at the user's initial capture action. Do not present these as an exact speed ratio.

Local receipt locations:

- `~/Library/Application Support/Quick Launch/chat-history.json`: Quick AI chat `97845F09-763E-4CAE-916C-6A74016E614E`; AI Chat `21A48EE5-3AEA-4DEC-BC8F-44E647D2144A`.
- `~/vault/kb/databases/projects/personal/rti/turns/2026-09-17.jsonl`: turn `2026-09-17T03:07:52Z`.
- Screenshots: `Screenshot 2026-09-17 at 11.07.39.png` (Quick AI), `11.07.55.png` (RTI), `11.08.17.png` (AI Chat).

The screenshot alone made Ghostty look like a possible invented detail. The saved input explicitly says `Context from Ghostty`; that claim is grounded in app metadata. Different screen descriptions cannot establish hallucination without the original captured pixels.

## What context means here

Context is everything supplied with a request, not just the words typed in the composer:

1. Instructions: the app's system prompt, selected assistant or mode, formatting rules.
2. Conversation: earlier questions and answers that still fit the request budget.
3. Chosen material: screenshots, selected text, files, links or RTI meeting context.
4. Retrieved material: memory or vault excerpts fetched before or during the answer.
5. Available tools: descriptions telling the model what it can request next. Availability is not evidence that a tool was used.

Neither ordinary screen question is automatically a Pi session with the full Pi instruction packet. Quick Launch can load instructions and skills for a selected assistant; RTI builds its own meeting-oriented prompt.

### Quick AI and AI Chat

Both use `QuickViewModel`, `OpenAICompatibleService` and the shared `QuickStore`. They have separate active drafts, streams and conversations, but shared settings, attachment memory and saved history. Moving a chat with Open in AI Chat transfers it; it does not create a separate copy.

For these screen turns, the saved user message contains the source app name and question, plus a screenshot reference. The attachment references, successful-answer receipts and current routing code indicate that the images accompanied the requests from session memory. This is source-based inference, not a retained network payload. The screen-awareness path can also gather selected text and accessibility text, depending on the capture/action path. That capability does not prove that all of those text fields were included in these two particular turns.

The current default system prompt asks for a fast, direct, concise result. However, memory, tasks, vault and skills are all enabled for new chats, and model web search is enabled. With no chat-level override in either saved object, both surfaces resolve the same tool policy. Tools only enter the request if their backing service is available.

Memory and vault are not unconditionally searched before every answer. The model requests them. Quick AI chose to retrieve here; AI Chat did not record such calls. Neither chat inherited earlier turns.

The no-hit memory response invites another query: “Try other words, or answer without memory and say it had nothing.” That can turn a simple screen question into another search and an unnecessary disclaimer. The eight displayed sources were memory hits from old session transcripts, not successful vault evidence.

Three recorded tool outcomes prove tool execution and at least one additional model continuation. They do not establish the number of model rounds because one response can request several tools. `Vault search failed` identifies the generic error branch, not the timeout branch. The error's cause and elapsed time were not retained, so it cannot be assigned a precise share of the delay.

Sources: `Sources/ViewModels/QuickStore.swift`; `Sources/ViewModels/QuickViewModel+ChatTools.swift:33–48`; `Sources/Services/OpenAICompatibleService.swift:45–105,232–259`; `Sources/Services/ChatToolbox.swift:229–278,413–455`; `Sources/Services/ScreenAwarenessService.swift`; `Sources/ViewModels/QuickViewModel.swift:7960–8074`.

### RTI

RTI builds context from its active mode, optional meeting/project material, recent transcript, earlier chat entries, explicit references and screen capture. It can retrieve vault material before an answer or let the model request tools. An explicit document or @ reference skips the automatic broad vault pre-search and adds instructions to answer from that material unless the user asks for wider research.

In the recorded turn, there was no live meeting transcript and no retrieval. Screen context was present, Meeting mode was active and Smart was off. Those are recorded facts; it does not follow that every RTI screen question is guaranteed to avoid retrieval. The explicit-source restriction applies to document references, not screenshots.

The system layers are ordered: base/mode instructions, meeting context, prep brief, discussion guide, glossary, mode reference, screen text, referenced documents. The transcript is added to the latest user message; the screenshot image also accompanies that message. The ordinary transcript window is 15 minutes, Quick recap uses 5 minutes, and Summary uses the full session and forces Smart. Brief, guide and mode reference each have an 8,000-character cap. This is a different budgeting scheme from Quick Launch's character-based estimate of the selected model's context window.

Manual screen context is consumed once. While recording, RTI can also include an ambient OCR trail: the last three retained events, capped at 5,000 characters. The manual OCR block allows 6,000 characters per display and 12,000 combined; the image is a JPEG with a 1,600-pixel long edge. RTI excludes itself and deny-listed applications at capture. The screenshot can therefore differ from Quick Launch's image in dimensions, content and added OCR even before the model runs.

Sources: `../rti/RTI/Core/LLM/PromptBuilder.swift:69–163`; `../rti/RTI/Sources/LLM/LLMController.swift:108–113,637–680`; `../rti/RTI/Core/Session/VisualContextEvent.swift:77–95`; `../rti/RTI/Core/Screenshot/ScreenFrameEncoder.swift:7–21`; `../rti/RTI/Sources/Screenshot/ScreenshotManager.swift:26–27,441–474`;  `../rti/RTI/Sources/LLM/LLMController.swift:196–278`; `../rti/RTI/Sources/LLM/AssistantTurnBuilder.swift:42–116`; the daily turn receipt above.

## Models and routing

### What is selected on this Mac

- Quick Launch text and vision both select DeepSeek API, `deepseek-flash`. The separate Quick AI model override is empty. Model preferences have no per-model overrides and reasoning effort is `modelDefault`.
- RTI has no saved provider override, so it resolves the built-in DeepSeek provider, `deepseek-flash`. Smart is false; the active mode is Meeting.
- The saved model fields agree across all three sample turns. Display names such as “DeepSeek V4.1 Flash” are app labels; they do not independently prove a particular provider-side revision behind the alias.

### Same model name, different request settings

RTI explicitly sends `thinking: disabled` for this turn, temperature 0.6 and an 8,192-token output ceiling. Quick Launch's `modelDefault` sends no thinking or reasoning-effort override, and its request builder does not set those same temperature/output fields. The provider decides defaults. There is no evidence that hidden reasoning explains this delay, but the apps do not currently guarantee identical generation settings.

Quick Launch supports configurable OpenAI-compatible providers, local servers and CLI-backed providers. Its saved choices include DeepSeek, Moonshot/Kimi, OpenAI, LM Studio, Local Models, Claude Code and Pi. Presence in the settings does not prove credentials, availability or successful execution. The CLI presets request nonpersistent sessions and disable Claude's tools or Pi's built-in tools/context files; choosing a CLI provider is a separate execution path, not the same native tool loop with another model name. Its runtime capabilities were not exercised here. RTI's built-in chat choices are DeepSeek, OpenAI (`gpt-4.1-mini`) and OpenRouter (`openai/gpt-4.1-mini`). It is a much narrower model interface.

In Quick Launch, an available image can route the entire request to the configured vision provider, including images from earlier turns still in memory. This is not necessarily “a local vision model describes it, then the chat model answers.” When no vision route exists, local OCR can supply text instead. Image routing is shown near the attachment; the history still stores only one model/provider pair for the whole conversation, rewritten as turns are sent. It cannot reliably attribute every older answer to its original model.

RTI's current screenshot path passes the image to its active vision-capable chat provider. A local-vision configuration still exists on this Mac (`qwen3-vl`, local daemon, enabled), but that configuration is not proof that the manual screenshot went through a local model. Current screenshot code explicitly avoids that extra vision call.

Sources: `Sources/Models/QuickSettings.swift:226–234`; `Sources/Models/InferenceProvider.swift`; `Sources/Models/ModelProfile.swift`; `Sources/Services/OpenAICompatibleService.swift:16–40,232–259`; `Sources/ViewModels/QuickViewModel.swift:8004–8067`; `../rti/RTI/Sources/LLM/LLMProvider.swift`; `../rti/RTI/Core/LLM/LLMProviderConfig.swift`; `../rti/RTI/Sources/LLM/LLMClient.swift:18–29,67–95,122–145`; `../rti/RTI/Sources/Screenshot/ScreenshotManager.swift`.

The apps also manage credentials separately. Quick Launch's API keys use the Mac's Keychain; RTI's `CredentialStore` uses `~/Library/Application Support/RTI/credentials.json`, written with owner-only permissions. This is neither a shared provider account store nor the same protection model. Credential values were not read. Sources: `Sources/Services/APIKeyStore.swift:13–49`; `../rti/RTI/Sources/Settings/CredentialStore.swift:4–22,70–125`.

### Privacy mismatch

Both app contracts retain local-only screenshot claims that conflict with current cloud-capable image requests. Quick Launch's contract says a user-copied screenshot “is routed locally”; RTI's says providers stay text-only and no image leaves the Mac. Current source and settings do not support those promises.

Local capture, local OCR, local storage and local inference are different properties. A screenshot can be captured locally, kept out of history, and still sent to DeepSeek. The apps need to name the actual destination before Send. Correcting a document alone would not settle whether cloud routing is the intended policy.

## Commands and new-chat behavior

Quick AI and AI Chat share `@`: typing a standalone `@` opens Add Context and removes the trigger from the draft. It is an attachment chooser, not a persistent mention language. A mid-word `@` does not trigger it. Choices include the available capture actions, File, Link and Finder Selection.

Their `/` mechanism mainly resolves saved prompt aliases and assistants. `/new` is not a built-in new-chat command; an unrecognized alias can fall through as ordinary model input. New Chat exists through keyboard/menu/header actions instead.

RTI has a built-in slash catalogue: `/new` and `/clear` clear the chat; `/screen` prepares one screen read; `/search` and `/rag` request vault search. Its @ path resolves vault file references rather than merely opening the same general attachment menu as Quick Launch.

Quick Launch's New Chat resets the thread and input, but attachment clearing is a separate reset scope. Pending attachments can therefore survive a new-chat action. The launcher also auto-starts a new conversation after the configured inactivity interval, currently 15 minutes. That interval does not apply to the AI Chat window.

RTI's `/new` clears pending attachment chips and screen context as well as the chat. It does not end a recording or clear its live transcript. “New chat” therefore must not imply “no meeting context.” The UI needs to show any meeting or project context that remains in force.

RTI's @ chooser turns a vault file into a chip, then emits a quoted path token at send time. Missing or ambiguous references stop the send. The file is read anew, with a 16,000-character cap per reference. This differs from Quick Launch's in-memory, hash-checked attachment snapshots.

The empty composer's Return action also differs in the screenshots: Quick AI offers Paste Response, AI Chat offers Copy Response, and RTI offers Quick recap. Quick AI's saved preference selects paste-to-active-app and auto-copy is enabled; AI Chat deliberately copies instead of pasting into another app. RTI's primary action is configured as Quick recap. Some difference follows each app's job, but pressing Return must not make the user guess whether it copies an existing answer or generates a new one.

These are semantic inconsistencies, not spacing or icon defects.

Sources: `Sources/Services/SavedPromptResolver.swift:36–89`; `Sources/ViewModels/QuickViewModel.swift:4700–4713,9343–9418,9761–9789`; `Sources/ViewModels/QuickViewModel+AIChat.swift:162–169,301–310`; `../rti/RTI/Core/LLM/ComposerState.swift:205–233`; `../rti/RTI/Sources/AppDelegate.swift:175–184`.

## Documents and attachments

Quick Launch has the broader ingestion path: PDF, Word-family files, PPTX, XLSX, text/code/Markdown, HTML, links and images. Files are read into bounded text or image context. They do not become a searchable document collection merely because they were attached.

Key limits in the current source:

- Documents: 50 MB; text files: 5 MB; up to 10 attachments and 6 images per message.
- Extracted text: 200,000 characters per attachment, 400,000 per message, then fitted to the model's context budget.
- PDF: 300 pages; OCR limited to 10 thin-text pages on the scanned-document path.
- PowerPoint: 300 slides; spreadsheet: 10 sheets, 5,000 rows, 100 columns.
- Spreadsheet extraction uses stored/cached values, not a spreadsheet calculation engine. Charts and layout are not carried as native workbook understanding.
- Image long side: 2,048 pixels. Large PNGs become JPEGs.

Truncation favors the beginning of a document. There is no question-based chunk selection over the attachment to rescue a relevant paragraph near its end. Readiness and truncation are represented in chips and request notices, but these limits still make “read this file” narrower than users may expect.

RTI's external chat attachment loader accepts text/Markdown and text-bearing PDF, with a 512 KB file cap and 24,000-character head excerpt. It does not provide Quick Launch's DOCX/PPTX/XLSX extraction or scanned-PDF OCR in that loader. Discussion-guide import is a separate feature, not evidence of general attachment parity.

Sources: `Sources/Models/ChatAttachment.swift`; `Sources/Services/Attachments/AttachmentExtractor.swift`; `PDFTextExtractor.swift`; `OOXMLTextExtractor.swift`; `Sources/Services/AttachmentRequestComposer.swift`; `../rti/RTI/Sources/LLM/ExternalDocumentAttachment.swift:49–120`.

## Where chats and their evidence go

### Quick AI and AI Chat share one local history

Owner: `~/Library/Application Support/Quick Launch/chat-history.json`, schema version 1. Current retention is 20 unpinned chats; pinned chats are exempt. The fresh-install default of 100 does not override this saved setting.

A conversation records ID, creation/update times, title, pin state, one provider/model pair, optional assistant ID and tool permissions. Messages record ID, role, content, optional attachment references, tool summaries/sources and question-card data. There is no recorded originating surface or full per-turn request manifest.

Attachment references retain names, kinds, sizes and applicable source/hash metadata. Extracted text and image bytes remain in a bounded session-memory store. Disk attachment caching is disabled. A restarted app can show the old conversation without possessing the file contents used to answer it. Files and links can be explicitly reattached; file hash changes are refused as the old attachment. Screenshots without retained source paths must be attached again.

The saved answer includes tool summaries and source paths, not the full tool result payloads, arguments or phase timings. Reopening a chat is therefore continuity of conversation text, not exact reproduction of its original evidence. A later model switch also changes the conversation-level label for older answers.

Sources: `Sources/Services/QuickHistoryStore.swift`; `Sources/Models/QuickConversation.swift`; `QuickMessage.swift`; `ChatAttachment.swift`; `Sources/Services/Attachments/AttachmentSessionStore.swift`; `Sources/ViewModels/QuickViewModel+Attachments.swift`.

### RTI uses vault logs and meeting archives

Standalone and meeting assistant turns append to:

- `~/vault/kb/databases/projects/personal/rti/turns/YYYY-MM-DD.jsonl`
- `~/vault/kb/databases/projects/personal/rti/chats/YYYY-MM-DD.md`

The JSONL has timestamp, action, mode, provider, model, Smart flag, session flag, transcript/screen-use flags, user input, transcript context, output, latency and sources. It has better per-turn model/timing evidence than Quick Launch, but no stable conversation ID, full prompt, screenshot payload, complete tool arguments/results or retrieval-adapter field. The readable daily file is a log, not equivalent to Quick Launch's resumable named chats.

Meeting completion writes a session folder under `…/rti/sessions/<timestamp>/`, with transcript and chat artifacts, nonempty notes/guide/live-intelligence/screen-context outputs, speaker names and retained audio. `session.json` records session ID, audio timing/files, mode, workstream, duration and calendar title. Five-minute checkpoints provide some crash recovery. During a recording, manual captures preserve JPEGs in `frames/`; the ambient capture path separately obeys its frame-saving configuration. The standalone screenshot turn did not have that session archive path.

The Sessions UI browses meeting archives, not the daily standalone `chats/` and `turns/` logs. Its Ask about this session action attaches a transcript reference; it does not restore the original prompt. Retention has no Quick Launch-style count cap. Archive deletion is a confirmed Move to Trash operation, and is blocked while an automatic upgrade is pending. Daily turn logs are separate records, so clearing the chat or deleting an archive should not be described as erasing all chat history.

RTI's external document loader keeps extracted text in memory rather than copying the source file into the archive. Logging an attachment name or path does not preserve the file's original bytes. Neither application's current chat record is sufficient for an exact request replay.

Sources: `../rti/RTI/Sources/Session/VaultLogStore.swift:10–106`; `../rti/RTI/Sources/Session/SessionArchive.swift`; `SessionArchiveMetadata.swift:7–26`; `SessionCoordinator.swift:754–763`; `../rti/RTI/Sources/UI/SessionsControl/SessionsWindowModel.swift:492–497,811–818,1349–1356`; `../rti/RTI/Core/Session/ArchivedChat.swift`; `../rti/RTI/Sources/LLM/ExternalDocumentAttachment.swift`.

## Is this RAG?

Partly. Retrieval-augmented generation means retrieving outside evidence and supplying it to the model. Embeddings are optional. Reading an attached file directly into a prompt is document context, not by itself a document-retrieval system.

There are different retrieval paths today:

1. **Quick Launch memory:** local `recall search`, deterministic keyword/line matching over memory Markdown. It ranks lexical matches, then file modification time. Old session transcripts can win; their modification date is not necessarily the date of the event being discussed. This explains why the eight source dates should not be read as eight recent decisions.
2. **Quick Launch vault:** SSH to `vault-vps`, then `.claude/tools/state/vault-search.py`, with current/reconcile/history/portfolio modes and an eight-second request deadline. The inspected local copy of this backend states it uses materialized project state and the document index, without an LLM, embeddings or reranker. The deployed remote copy was not compared. The sample call failed; its specific cause is unknown.
3. **RTI vault:** code attempts a hybrid Neon CLI and otherwise uses local keyword search. The configured resolver points to `~/vault/code/hermes/src/cli.ts`, which is absent on this Mac. It therefore cannot enter that semantic path in the audited install. A successor exists at `~/vault/code/vault-search/src/cli.ts`; its contract appears compatible but was not executed or adopted by this audit.

RTI's fallback returns short lexical excerpts from vault Markdown. Files over 256 KB and several raw-data directories are excluded. It is useful retrieval, but it does not have the recall of a working semantic index. Some in-session tracing identifies the adapter; the durable turn log does not.

Missing across the apps: one retrieval contract, explicit source authority/freshness, reliable health reporting, attachment chunk retrieval, consistent citation precision, and tests that distinguish “no evidence” from “retrieval unavailable.” Adding another vector database would not resolve the unnecessary searches in this screen example.

Sources: `../memory-recall/Sources/RecallCore/MemorySearch.swift:71–155`; `Sources/Services/RecallCLI.swift`; `Sources/Services/VaultSearchService.swift:66–141`; `~/vault/.claude/tools/state/vault-search.py`; `../rti/RTI/Sources/LLM/VaultSearchCLI.swift:20–44,107–111`; `VaultRetrieval.swift:78–131`; `VaultSearch.swift:29–40,184–207,267–296`.

## Recommended harmonization

Keep the three jobs: Quick AI for fast actions, AI Chat for longer conversations, RTI for meetings. Share the behavior that a user should not have to relearn.

### First: make explicit-source questions fast and predictable

When a screenshot or document is attached and the question is about that source, answer from it first. Do not offer broad memory/vault retrieval for that turn unless the user requests comparison, history, verification or wider research. This should be an application policy with tests, not merely another sentence asking the model to be concise.

Measure capture, extraction, first token, tool time and total time separately. Compare the three surfaces with the same captured image, question and generation settings. The current receipts prove the unwanted retrieval; they do not provide that controlled benchmark.

### Second: make routing and retrieval health honest

Show the effective model, cloud/local destination and reasoning setting at send time and in the completed turn. Resolve the screenshot privacy policy before changing either code or promises. Repair and independently test RTI's stale semantic-search path, or explicitly retire that capability. Diagnose Quick Launch's vault failure separately; the two apps do not call the same adapter.

### Third: one command and context contract

- `/new` and the New Chat button should perform the same chat reset everywhere. This is already the user's requested direction.
- Starting a new chat should make attachment carry-over explicit. Recommended default: clear the chat's pending attachments and selection; keep RTI recording running and visibly identify any retained meeting/project context.
- Use `@` and `+` as consistent entry points to a searchable context chooser. Give Files, Screen, Selection and Links the same names and previews. RTI can add Meeting/Transcript and project-file choices without changing the basic interaction.
- `/` should show built-in commands before user-defined prompts. Reserve control words such as `new` so an assistant alias cannot replace a local command.
- Distinguish New Chat, Clear Draft, Remove Context and Delete History. Do not label all four “clear.”

### Fourth: a common turn record, without a new store

Extend each existing owner with compatible per-turn metadata: conversation/turn ID, originating surface, effective model/provider/endpoint class, reasoning mode, prompt version/hash, selected context references and hashes, extraction/trim notices, tool names and argument summaries, result status, retrieval adapter, timing phases and token usage when supplied.

Keep source files in their current owners. Decide explicitly what attachment content, if any, may persist; do not silently turn ephemeral screenshots or documents into a permanent shared index. Add visible “content unavailable after restart” states and reliable reattachment.

### Then: improve document retrieval where it earns its cost

Reuse a shared extractor so the same PDF or Office file has the same support and limits in each app. For long-document questions, retrieve relevant chunks with page/slide/sheet citations instead of always taking the head. Mark excerpts, cached spreadsheet values and OCR limits. Confirm what the model actually received before treating its answer as a full-file review.

### Acceptance cases

1. Same image + “what is this?” produces no memory/vault calls by default on all three surfaces.
2. “Compare this with our earlier decision” opts into scoped retrieval and returns checkable source locations.
3. `/new` clears the chat and its pending context consistently; RTI recording remains running and retained meeting context remains visible.
4. A cloud-bound image names the destination before sending; the completed turn retains the effective model.
5. Restarting either app does not imply an ephemeral attachment is still loaded.
6. A failed semantic index is shown as degraded retrieval, never as “the vault has no evidence.”
7. A fact near the end of a long document is either found with a location or explicitly outside the supplied context.
8. Moving a Quick AI chat to AI Chat preserves its turns, sources and attachment availability without duplication.

## Verification status

A fresh verifier independently confirmed installed build identity, the three saved timing/tool receipts, the missing RTI semantic CLI path and both screenshot-policy mismatches. Cloud image routing is established from source and saved configuration, not a captured network request.

`swift test --skip-build --filter 'ToolLoopTests|AIChatToolParityTests|AttachmentPrivacyTests|ContextBudgetTests'` passed 28 tests in four suites. The cached test bundle predates HEAD, so this is limited regression evidence, not verification of the current revision. No rebuild, RTI UI test, provider request or controlled speed benchmark was performed.

A second independent pass found no material blockers and requested two precision fixes: label image transmission as source-inferred, and distinguish manual frame retention from the ambient saving setting. Both are incorporated. The four prose gates passed before these final wording fixes. The audit report is the only new repository artifact. No behavioral fixes or settings changes are claimed.
