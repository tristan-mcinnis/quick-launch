# Quick Launch AI: from Quick AI to AI Chat, systems on systems

Plan, 2026-09-11, revision 2 (after an adversarial review on Opus). Written
after v1.4.0 shipped the Raycast-shaped Quick AI surface and v1.4.1 fixed the
model id. Inputs: Raycast's Quick AI and AI Chat manuals; a UX review of the
new surface; read-only maps of Quick Launch, the pi agent, the memory layer,
the vault, the skills folders, PI-Desktop, and Onyx. Nothing below is built
unless marked shipped.

## 0. The thesis

Yes to AI Chat, no to a fork. Every "power" feature (vault, memory, skills,
pi) is a **tool the model can call** or a **hand-off you invoke**, never a new
engine inside the app. The engines already exist as CLIs on this Mac: `recall`
for memory, the SSH vault lane the app calls today, pi with its sessions and
RPC mode. Quick Launch stays a launcher plus an AI surface. Anything that needs
autonomy, projects, files, or long tool chains goes to pi.

The review agreed with the tool-and-hand-off half and rejected my first window
design. The window section below is the corrected one.

## 1. Shipped today

| Version | What |
|---|---|
| v1.4.0 | Quick AI is the Raycast surface; Tab sends; ⌘J Recent Chats; clarifying questions off by default |
| v1.4.1 | DeepSeek on `deepseek-flash`, the only flash id the DeepSeek API lists. It is DeepSeek V4.1 Flash, it reads images (tested), and it is the id pi uses. `deepseek-v4-flash` and `deepseek-v4-flash-vision-exp` were aliases of it; settings migrated (configuration version 24). |
| v1.5.0 | Phase A1 (items 1, 2, 6, 7, 8, 9, 10, 12, 15): answers never collapse; Show more and Collapse scroll the head to the top; the threshold is measured at the thread's width; Recent Chats search; cleaned-up titles; state-aware placeholder; Copy Answer stays open, Copy Chat (`⌥⌘C`); empty-state hints; the model line opens the chooser |

## 2. Did v1.4.0 take liberties?

Mostly no. Four changes reach outside the Quick AI surface.

| Change | Required by the spec? | Keep? |
|---|---|---|
| Root panel 720 to 750 pt wide | Yes. It matches Raycast and stops the window jumping on Tab | Keep |
| Every answer lane now opens the Quick AI thread: local math ("2+2" shows "4" under the model name), command actions, Vault Search, transforms | **No, a liberty.** The rebuild tied the surface to "any output" | **Fix in Phase A** (defect 16) |
| Launcher magnifier and Translator glyph 18 to 16 pt | No. Side effect of removing a hard-coded size for the design lint | Keep; say if you want 18 back |
| Answer line spacing tightened (about 5 pt leading, was about 8) | No, but it was a bug: the old maths added the full 0.55 on top of SF's own leading | Keep |

Unchanged: root search rows, catalogs (clipboard, snippets, colors, screen
history, chats), ⌘K, the footer well on root, every shortcut's meaning, the
choosers (moved into shared views, same look), Manage Models, settings panes
other than Quick AI.

## 3. Phase A: make Quick AI feel finished

Defects from the UX review, verified in code. Size: S small, M medium.

| # | Defect | Fix | Size |
|---|---|---|---|
| 1 | A long answer folds itself the moment streaming ends | Never collapse assistant turns. Raycast collapses only what you send | S |
| 2 | Expand and Collapse do not scroll (your example) | Scroll the message head to the top of the view on both; ⇧⌘M targets the newest collapsible turn | S |
| 6 | Collapse threshold assumes 60 characters a line; the thread fits about 100 | Measure by width | S |
| 7 | Recent Chats has no search | The composer filters titles and content while the list is up | S |
| 8 | Title is the raw first message, lowercase | Capitalise, cut at a word, strip `/alias` and "search web"; a generated 3 to 6 word title later | S |
| 9 | Placeholder never changes | "Ask a follow-up…" once a thread exists | S |
| 10 | Copy Answer closes the window, no feedback | Stay open, checkmark in the composer; add Copy Chat | S |
| 12 | The empty surface is a blank 475 pt | Three quiet hints: `@` context, ⌘J chats, ⇧⌘O model | S |
| 15 | The model line is plain text | Make it a button for the model chooser | S |
| 16 | Local answers (math, commands, Vault Search) land in the AI thread under the model name | Math answers inline in root search, as before and as Raycast's calculator does. Command and Vault Search output get their source name in the header and stay out of the chat history | M |
| 5 | ↓ on an empty composer switches chats | ↑ on empty recalls the last question (Raycast). PageUp/PageDown and ⌥↑↓ scroll the thread; ⌘↑↓ jump. ⌘[ ⌘] stay for chats | M |
| 3 | Stop throws away the partial answer; ⌘R then regenerates the wrong turn | Keep the turn and the partial text; ⌘R re-asks that turn | M |
| 4 | Streaming pulls to the bottom on every update | Follow the bottom only when you are near it; a "↓ Latest" chip otherwise | M |
| 11 | An error deletes the question | Keep the turn, show the error under it, "Retry ⌘R" | M |
| 13 | Return while streaming does nothing | Queue one follow-up, send it when the stream ends | M |
| 14 | ⌘K on a Recent Chats row acts on the open chat | Act on the highlighted row; pin glyph on the row | M |

Split into A1 (the ten S items) and A2 (the six M items). The review was
right that my first estimate hid this: A1 is about the size of one v1.4.0
workflow run; A2 is another, because five of the six live in the
6,900-line view model. Each run ends with tests, render proofs, and a live
check with the panel confirmed open before any key.

## 4. Phase B: AI Chat, the window

### 4.1 What went wrong in draft 1

Draft 1 proposed a 960 × 640 window with a chat rail, the thread, and a
settings panel, justified by "the launcher closes on focus loss". Both parts
were wrong. The launcher panel already survives focus loss and is already
resizable (`AppDelegate.swift:510`, `:554`). And a rail beside the thread is
the split you rejected this morning.

### 4.2 The corrected shape

- **B1, resizable Quick AI.** Let the Quick AI surface resize and remember
  its size, with 750 × 475 as the minimum. This alone answers "I need more
  room for a longer chat". Size S. Shipped in v1.5.0: drag any edge while
  Quick AI is up, the size persists, the thread stays a centred column,
  `⌘K` › Reset Quick AI Size.
- **B2, AI Chat window.** A separate, normal window (it shows in ⌘Tab and
  Mission Control and stays open while you use the launcher for something
  else, which the launcher panel cannot do). Inside it: the same thread and
  composer as Quick AI, with a chat list that is **hidden by default** and
  slides in on a key, Raycast's sidebar without a permanent split. Search and
  pin in the list; archive later; no Recently Deleted (the contract says
  bounded history). Multi-line composer (⇧↵ newline), find in chat (⌘F).
  Size M to L.
- Window size from the design system: settings is 860 × 620 and the rail is
  220 there. AI Chat reuses those numbers unless a token change lands in
  `design-system` first.
- Keys: ⌘J in Raycast means "continue in AI Chat". Once B2 exists, ⌘J does
  that, and Recent Chats in Quick AI moves to another key checked against the
  shortcut table. `/` stays saved prompts; the model chooser is ⇧⌘O.

### 4.3 Contract gate

`CLAUDE.md` says Quick Launch is "not a general chat workspace". Before B2
starts, the contract gets a boundary sentence: "AI Chat is one conversation
window over the same providers and tools. No autonomy, no projects, no
automations, no file changes; those belong to pi."

## 5. Phase C: tools inside the chat

> Shipped in v1.5.0. What landed differs from the plan below in three places.
> Citations needed no remote change: `vault-search.py` already returns
> `source_path` (vault-relative, or under `/home/ubuntu/vault-private/`), a
> title, and dates on each `evidence` or `results` row, so the app reads them
> from the JSON it already gets and maps them onto `~/vault/`. The context
> budget cuts rather than summarises: the results of the answer's older tool
> rounds, then oldest turns, then the newest round's results, never the first
> or the current question, with a line saying what was left
> out. Capture to Memory is on the answer on screen (the thread has no
> message selection), `⌥⌘M`. Tools per chat live in `⌘K` › Tools (`⌥⌘K`);
> the wall-clock budget is 30 seconds, not counting time on a question card.

The app declares two tools today (`search_web`, `ask_user_question`) in
`OpenAICompatibleService` and runs them itself, three rounds at most. New
tools follow the same pattern: a CLI called with an argv array, no shell, a
timeout, and a line in the thread ("Searched memory: 4 hits").

| Tool | Backed by | Latency | Writes? | Default |
|---|---|---|---|---|
| `recall_memory(query)` | `recall search --json` over `~/memory` | about 0.3 s, local | no | on |
| `recall_today()` | `recall today --json` | fast, local | no | on |
| `search_vault(query, mode)` | the existing SSH lane (`vault-search.py` on vault-vps, four modes, JSON) | 1 to 9 s | no | on; one try, 8 s, then "timed out" to the model; no retry |
| `read_skill(name)` | `~/.claude/skills/<name>/SKILL.md`, name checked against the real folder list | instant | no | on |
| `capture_thought` | **not a model tool.** `memory-capture.py` accepts only your own words. Instead: a ⌘K action "Capture to memory" on any message, through `recall remember` | | you trigger it | |
| `run_skill` | **not built.** The write skills (email, Slack, calendar, Float) have policy gates a model tool would skip | | | |

Also in Phase C:

- Raise the round limit from 3 to 6, with a wall-clock budget, so memory plus
  vault plus a skill fit in one answer.
- Citations need a data change first. The vault lane returns rendered text
  with VPS paths today. It must return hits (path, title, date) and map
  `/home/ubuntu/vault-private/` to `~/vault/`, so a source opens on the Mac.
  This is the Onyx idea worth keeping: retrieve, answer, cite, click through.
  The index itself is the vault's existing Neon/pgvector; the app indexes
  nothing.
- A context budget: long chats plus tool output need trimming or a summary
  step, which `QuickConversation` has no notion of today.
- Tool descriptions tell the model when to call each tool ("only when the
  user asks about their own projects, clients, decisions, or files"), so the
  slow vault tool is not called on "what is 17 × 23".

## 6. Phase D: assistants

`SavedPrompt` already carries a name, alias, model, provider, and hotkey. Add
`systemPrompt`, `enabledTools`, and `contextRefs`, and treat a saved prompt
with no command as an assistant. Pick one with `/name` (the prefix you already
use) or ⌘K › Change Assistant. That gives "vault researcher", "STE editor",
"China Snapshot desk" as one keystroke each. Raycast calls these Agents; Onyx
calls them Assistants. Size S to M.

## 7. Phase E: flip to pi

What exists: a "Pi tools and skills" provider that runs
`pi --print --no-session --no-context-files --no-builtin-tools`. It is
one-shot on purpose and cannot use any pi tool.

**Continue in pi**, a ⌘K action (key chosen later):

1. Write the thread to a Markdown file in the app's support folder.
2. Start a new tmux session for it, in the chat's folder (or `~`), running
   `pi @<thread.md> "Continue this conversation from Quick Launch."`. A fresh
   session, not a hand-written session file: pi's session format needs tree
   ids, typed content blocks, and usage records the app does not have, and
   the path rule in pi's own docs does not match what is on disk. A fresh
   session also survives pi changing its format.
3. Open Ghostty attached to that session. Your tmux sessions are numbered
   (112, 113, …), so this creates its own session instead of attaching to
   one called `pi`, which would silently drop the command.

Size S. The gate is a round-trip test: the thread arrives in pi and pi's
subagents and web tools work in that session.

**Later, only if you use Continue in pi a lot:** a `pi --mode rpc` provider
that keeps one pi process per chat, so a chat runs on pi without leaving the
window. Size L, and it needs a tool-approval UI.

PI-Desktop is not a lane: no deep link, no socket, manual import only, not
installed, and you said no fork.

## 8. What stays out

Dictation (local-dictation owns it). A second memory (`~/memory` is the
memory). Projects and working folders (pi). Automations (the vault loops).
Image generation (the nanobanana skill). MCP servers (pi). Edit-and-rerun,
branch chat, and Recently Deleted: not now; revisit after B2 is in use.

## 9. Order

| Phase | Scope | Size |
|---|---|---|
| A1 | the ten small Quick AI fixes | one run |
| A2 | the six medium Quick AI fixes | one run |
| B1 | resizable Quick AI | small |
| C | memory, vault, and skill tools; round limit; citations data change; context budget | one to two runs |
| E | Continue in pi | small |
| D | assistants | small to medium |
| B2 | AI Chat window, after the contract gate | one to two runs |

C and E come before B2 on purpose. They give you vault, memory, skills, and
pi from the surface you already use every day, and they will show whether a
second window is still wanted once Quick AI can resize.

## 10. Sources

- Raycast manual: Quick AI and AI Chat pages, read 2026-09-11.
- `docs/quick-ai-raycast-surface-20260911.md`, `docs/quick-ai-parity-20260911.md`.
- pi 0.85.1 docs: `session-format.md`, `rpc.md`, `usage.md` under the npm
  package; `~/.pi/agent/{AGENTS.md,settings.json,models.json}`.
- `~/memory/CLAUDE.md`, `memory-capture.py --help`, `recall --help`;
  `VaultSearchService.swift`.
- DeepSeek API `/models` and a vision call, 2026-09-11.
- PI-Desktop v0.14.6 source; Onyx README.
