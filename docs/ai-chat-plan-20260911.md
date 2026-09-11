# Quick Launch AI: from Quick AI to AI Chat, systems on systems

Plan, 2026-09-11. Written after v1.4.0 shipped the Raycast-shaped Quick AI
surface. Inputs: Raycast's Quick AI and AI Chat manuals, a UX review of the
new surface, and read-only maps of what already exists in Quick Launch, the
pi agent, the memory layer, the vault, the skills folders, PI-Desktop, and
Onyx. Nothing here is built yet.

## 0. The answer in one paragraph

Yes to AI Chat, no to a fork, and no to ambition for its own sake. The right
shape is Raycast's: Quick AI stays the fast lane; AI Chat is the same thread
model in a bigger, resizable window with a chat list; every "power" feature
(vault, memory, skills, pi) is a **tool the model can call** or a **hand-off
the user can invoke**, never a new engine inside the app. The engines already
exist and are already on disk as CLIs: `recall` for memory, the SSH vault
search lane the app calls today, pi's documented session format and RPC mode.
Quick Launch stays what its contract says: a launcher and an instant AI
surface, "not a general chat workspace or an autonomous desktop agent". AI
Chat is the ceiling of that contract, and pi is where anything past the
ceiling goes.

## 1. First, fix what v1.4.0 got wrong

These are defects, not polish. Ship them before AI Chat. Costs: S under half a
day, M a day, L more.

| # | Defect | Now | Fix | Cost |
|---|---|---|---|---|
| 1 | A long answer folds itself the instant streaming ends | The finished text becomes a message, not in the expanded set, so anything over 10 estimated lines snaps to a 6-line preview | Never collapse assistant turns (Raycast only collapses what *you* send); collapse user pills only | S |
| 2 | Expand and Collapse do not scroll (the example you gave) | `toggleTranscriptMessage` flips a set; the only scroll target is the bottom anchor | A `scrollRequest(id, anchor: .top)` on toggle, so the head of the message lands at the top of the viewport both ways; ⇧⌘M targets the newest collapsible turn | S |
| 3 | Stop discards the partial answer; ⌘R then regenerates the wrong turn | `cancel()` clears output and rolls the question back into the composer | Keep the turn and the partial text as the answer; ⌘R re-asks that turn; roll back only when Stop lands during web-search enrichment | M |
| 4 | Streaming yanks to the bottom on every flush | Cannot scroll up to re-read while the model writes | Track "near bottom"; auto-scroll only when near bottom or on a new turn; a small "↓ Latest" chip when detached | M |
| 5 | ↓ on an empty composer switches chats | Legacy browse binding | ↑ on empty = recall last question (Raycast); PageUp/Down and ⌥↑↓ scroll the thread; ⌘↑↓ top/bottom; ⌘[ ⌘] stay for chats | M |
| 6 | Collapse threshold assumes a 60-character line | Thread is 690 pt, about 100 characters a line; a 7-line paragraph counts as 12 | Measure by width and font, or 95 characters for the thread | S |
| 7 | Recent Chats has no search | Typing goes into the composer and does nothing | Composer filters title and content while the list is up; placeholder "Search chats…" | S |
| 8 | Title is the raw first message, lowercase | "raycast founder" | S: capitalise, cut at a word, drop "?" and slash prefixes. M: one small background call for a 3-6 word title after the first answer; rename still wins | S then M |
| 9 | Placeholder never changes | Static string | "Ask a follow-up…" once a thread exists; "Waiting… esc stops" while streaming | S |
| 10 | Copy Answer closes the window and shows no feedback on this surface | Checkmark lives on the root surface only | Copy Answer stays open, checkmark in the composer 1.5 s; add Copy Chat (⌥⌘C) with role labels | S |
| 11 | An error deletes the question and offers no retry | Rollback plus a bottom error line | Keep the turn, draw the error as a tool line under the question, "Retry ⌘R" | M |
| 12 | Empty surface is a 475 pt void | Blank | Three quiet hints: `@` adds context, ⌘J recent chats, ⇧⌘O change model | S |
| 13 | Return while streaming does nothing | Swallowed | Queue one follow-up, label "Queued ↩", send at stream end | M |
| 14 | ⌘K on a Recent Chats row acts on the *current* chat | Pin/Rename/Delete target the open thread | Target the highlighted row; pin glyph in the row | M |
| 15 | Model line is plain text | Not clickable | Button opening the model chooser; `/` in the composer too (Raycast) | S |

Order: 1, 2, 5, 3, 4, then the S items in a batch, then 11, 13, 14. That is
about four working days and it makes Quick AI feel finished before anything
new is added.

## 2. Did v1.4.0 take liberties?

See section 8 for the audit table. Short version: the rebuild is contained to
the Quick AI surface, the Tab behaviour, ⌘J, the clarifying-question setting,
and the model default. The root launcher, every catalog, ⌘K, the footer well,
the choosers and the shortcuts are unchanged in meaning. Two things changed
outside Quick AI that you should know about: the root panel is 30 pt wider
(750, the Raycast width, so the window does not jump on Tab), and the
Transform, Model and Add Context choosers were moved into shared structs so
both surfaces draw the same one. Both are on purpose and in the spec.

## 3. AI Chat: what it is and what it is not

Raycast's AI Chat, distilled from the manual:

- A separate window, resizable, optional Always on Top, with a chat list on
  the left (search, pin, archive, rename, delete, recently deleted), the thread
  in the middle, and a per-chat settings sidebar (model, tools on or off).
- ⌘J from Quick AI moves the thread over with history, model and attachments.
- Attachments and `@`: files, clipboard items, browser tabs, selected text,
  windows, screenshots, calendar events; scoped to the message.
- Tools per chat: web search, image generation, terminal, extensions, MCP;
  auto-approve routine calls, prompt for the rest.
- Edit a previous message and re-run; queue or steer follow-ups; ⌘F find in
  chat; branch a chat; auto-summarise long chats; "Memory" of durable facts;
  Skills as `SKILL.md` files; Projects with instructions and a working
  directory; Automations on a schedule.

For Quick Launch, the line is: **build the window, the chat list, the tools,
and the hand-offs; do not build agents, projects, automations, or a second
memory.** Those already exist as pi, the vault, and `~/memory`. Building them
twice is the "parallel registries" mistake your own rules forbid.

### 3.1 Window

- A second `NSPanel` (or a plain resizable `NSWindow`, since it should survive
  focus loss unlike the launcher) at 960 × 640 default, min 720 × 480,
  remembering its frame, optional Always on Top. Same glass, tokens, and
  `QuickAIView` thread. New tokens: `Layout.chatWidth`, `chatHeight`,
  `chatRail` (260).
- Layout: rail 260 (chat list with a search field at the top and Pinned then
  Recent sections), thread (the existing `QuickAIView` thread and composer,
  reused as-is), and a collapsible right panel for per-chat settings (model,
  tools toggles, reasoning effort). No third pane by default; ⌘⇧S shows it.
- ⌘J in Quick AI opens AI Chat on the same conversation id and closes the
  launcher. ⌘J in AI Chat with the launcher closed opens the launcher's
  Quick AI on the same thread (symmetry, cheap). The current one-column
  Recent Chats stays in Quick AI for the fast lane.
- Shared store: `QuickHistoryStore` already holds conversations, pin, rename,
  delete. Add `archivedAt`, `deletedAt` (60-day Recently Deleted), `projectID`
  optional later. One store, two views.
- Keys as Raycast: ↵ send, ⇧↵ newline (the composer becomes multi-line here),
  ⌘N new, ⌘R regenerate, ⌘F find, ⌘K actions, ⌘1…⌘0 jump to chats,
  ⌃⇧X delete unpinned.

### 3.2 Tools inside the chat (the "flow together" part)

The app already declares tools to the model (`web_search`,
`ask_user_question`) in `OpenAICompatibleService` and dispatches them itself.
Every new capability is one more entry in that list, each backed by a CLI the
app calls through `ProcessRunner` with an argv array, no shell, a timeout,
and a visible tool line in the thread ("Searched memory: 4 hits"). Approval
follows Raycast: reads auto-run; writes prompt inline with the existing
Ask User Question card.

| Tool | Backed by | Latency | Side effects | Default |
|---|---|---|---|---|
| `recall_memory(query)` | `recall search --json` (local byte scan over `~/memory`, ~0.3 s) | fast | none | on |
| `recall_today()` | `recall today --json` | fast | none | on |
| `search_vault(query, mode, type, project, since)` | the existing SSH lane (`vault-search.py` on vault-vps, JSON, 8 s timeout) that the Vault Search catalog already uses; `vault-query.py search --json` for typed filters | 1 to 9 s | none | on, with the timeout and one retry |
| `capture_thought(text, project)` | `memory-capture.py add` without `--execute` (triage only) | fast | writes the inbox | on, shows the line "Captured to memory inbox" |
| `read_skill(name)` | reads `~/.claude/skills/<name>/SKILL.md` (canonical) | instant | none | on |
| `run_skill(name, args)` | **not built** as a blanket dispatcher; the write-capable skills (email, Slack, calendar, Float) have policy gates that a model tool would bypass | | | off; revisit with an allowlist of read-only skills (`searxng`, `neon` read) |
| `web_search` | as today | | | on |

Citations: when `search_vault` or `recall_memory` returns hits, the answer
gets a source list under it (file path, day, line) in the tool-line style,
and each hit is a ⌘K action "Open source" (`open` the file, or reveal in the
vault). That is the Onyx idea worth keeping: retrieve, answer, cite, click
through. The retrieval itself is already the VPS Neon/pgvector index the vault
ingest fills; the app does not index anything.

Per-chat tool toggles live in the right panel and in `⌘K` › Tools. Quick AI
gets the same tools with the same defaults; there is no reason the fast lane
should be dumber.

### 3.3 Assistants, the Onyx-style persona

You have Saved Prompts and AI Commands already. Promote them: an Assistant is
a name, instructions, a default model, a tool set, and a fixed context
(`read_skill` names or vault project). `⌘K` › Change Assistant, and `/name`
in the composer. It is a small model on top of `SavedPrompt`, stored in
settings, no new store. This gives you "the vault researcher", "the STE
editor", "the China Snapshot desk" as one keystroke each, which is what
Raycast calls Agents and Onyx calls Assistants.

### 3.4 Flip to pi

pi has two documented programmatic surfaces and no daemon:

- Session files: `~/.pi/agent/sessions/--<cwd-with-dashes>--/<timestamp>_<uuid>.jsonl`,
  a `session` header line then `message` entries. pi resumes one with
  `pi --session <path>`.
- `pi --mode rpc`: JSONL over stdin/stdout with `prompt`, `steer`,
  `follow_up`, `abort`, `get_state`.

Hand-off, cheapest first:

1. **Continue in pi (⌘⇧J).** Quick Launch writes the thread as a pi session
   file (user and assistant messages, model id, cwd = the chat's working
   directory or `~`), then opens Ghostty with `tmux new -A -s pi` and
   `pi --session <path>`. One command, zero pi changes, and pi's own
   extensions (pi-dash, computer use, web search) are all live. This is the
   "it needs a longer, tool-using conversation" exit. Cost S.
2. **pi as a provider inside AI Chat.** A `commandLine` provider kind exists
   for `claude -p`. Add a `pi --mode rpc` provider that keeps one pi process
   per chat and maps `prompt` / deltas / `abort`. Then a chat can run on pi
   without leaving the window, with pi's skills and tools. Cost M to L, and
   it drags a tool-approval UI in with it. Do this only after 1 has been used
   for a few weeks and the demand is real.

PI-Desktop is not a lane: no deep link, no socket, manual import only, not
installed, and you said no fork. pi's session format is the interchange, and
PI-Desktop reads that same format if you ever want it.

### 3.5 What stays out

Dictation (local-dictation owns it), a second memory (`~/memory` is the
memory; the `recall_memory` tool reads it and `capture_thought` writes its
inbox), projects with working directories (that is pi), automations (that is
cron and the vault loops), image generation (nanobanana skill exists; a tool
later if wanted), MCP servers (pi has them).

## 4. Sequence

| Phase | Scope | Cost | Gate |
|---|---|---|---|
| A | Section 1 defects 1 to 15 in the order given | 4 days | swift test, render proofs, driven check with the panel key |
| B | AI Chat window: second window, rail with search and pin and archive, thread reuse, ⌘J both ways, multi-line composer, find in chat | 4 to 5 days | design registry entry for the chat window; proofs both appearances |
| C | Tools: `recall_memory`, `recall_today`, `search_vault`, `capture_thought`, `read_skill`, tool lines and citations, per-chat toggles | 3 days | each tool has a fixture test with a fake ProcessRunner; timeouts proven |
| D | Assistants on top of Saved Prompts; `/name` and Change Assistant | 2 days | |
| E | Continue in pi (session file + Ghostty) | 1 day | round-trip test: written file resumes in `pi --session` |
| F | pi as an RPC provider | later, only on demand | |

Phase A alone makes Quick AI feel right. B plus C is the "clean Raycast AI
Chat". D and E are the parts that make it yours. Each phase is one workflow
run with the same shape as v1.4.0: implement, prove, three-lens review, fix.

## 5. Risks and honest notes

- Latency. `search_vault` is an SSH round trip of 1 to 9 s. The tool line
  must show progress and the model must not call it speculatively; the tool
  description should say "only when the user asks about their projects,
  clients, decisions, or files".
- The Claude CLI provider has no streaming or tools. AI Chat on that provider
  will be text-only; say so in the model line.
- A second window changes the app's identity a little. The contract's "not a
  general chat workspace" line needs one sentence added: AI Chat is a
  conversation window over the same providers and tools, with no autonomy.
- `run_skill` is the one thing that looks small and is not. Skip it.

## 6. Decision needed from you

Only one: confirm Phase A first, then B and C as one block. Everything else
follows from that order and needs no further call.

## 7. Sources read

- Raycast manual: Quick AI, AI Chat (2026-09-11).
- `docs/quick-ai-raycast-surface-20260911.md`, `docs/quick-ai-parity-20260911.md`.
- pi: `/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/docs/{session-format,rpc,json,sdk}.md`, `~/.pi/agent/{AGENTS.md,settings.json,models.json}`.
- Memory and vault: `~/memory/CLAUDE.md`, `~/memory/ops/*`, `~/vault/.claude/tools/state/vault-query.py`, the app's `VaultSearchService.swift`, `~/Documents/code/house/memory-recall`.
- PI-Desktop: `~/Documents/code/example-sites/PI-Desktop-IC` at v0.14.6 (importers, host-core RPC, no deep link).
- Onyx README (MIT; hybrid search, citations, assistants).

## 8. v1.4.0 scope audit

(filled from the audit; see below)
