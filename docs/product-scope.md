# Product scope

Quick Launch is a keyboard-first launcher. The current build handles these jobs:

1. Launch apps.
2. Translate or transform selected and typed text.
3. Ask Quick AI and keep the chat, or run a saved AI action.
4. Run local date, time, and math actions.
5. Retrieve bounded SearXNG snippets for explicit or time-sensitive searches.
6. Paste a local snippet.
7. Open a local Quick Link.
8. Search and paste a bounded local clipboard history (text, images, rich text, and files).
9. Resize the previous window into deterministic whole-screen, halves, thirds, two-thirds, and fourths layouts, or move it to another display.
10. Keep the Mac awake with a native Caffeinate toggle or a timed session.
11. Paste emoji and symbols by name.
12. Translate typed or selected text between Chinese and English with one key.
13. Attach a fresh or saved screenshot to a question and follow up on it.
14. Search current project state, post-meeting changes, project history, and cross-project status through the VPS-backed Vault Search catalog.
15. Pick a colour from any pixel on any display, copy it as Hex, RGB, HSL, or HSB, and search a bounded local history of picks.
16. Read the text inside a dragged screen area on this Mac and copy or paste it.
17. Type to Click: label every clickable control in the frontmost app and click one by typing its name.
18. Hold one conversation in the AI Chat window, over the same providers and tools as Quick AI.

Screenshot capture to the chat context is in the core: a window or display
capture attaches to one question and follow-ups in that thread, never to
history or disk. The Screenshots catalog manages saved screenshot files, and the
Translator window (`⇧⌘T`) is the two-pane translation tool. The Translate saved
actions stay configurable selected-text AI actions.

It does not need general Finder file search. AI Chat is one conversation window over the same providers and tools. No autonomy, no projects, no automations, no file changes; those belong to pi. The search-only beta hard-locks ambient capture. A later capture release still needs separate explicit consent and will keep all browsers blocked.

Files and links attached to a chat are implemented; the design spec is
`docs/attachments-and-search-spec-20260911.md` and the behavior reference is
[`docs/features.md`](features.md#attachments).

Refactor plans: `docs/consistency-audit-20260902.md` (keyboard layers, overlay modes, persistence, view styling) and, after the v1.5 rebuild, `docs/consistency-audit-v1.5-20260911.md`.

## Quick AI and AI Chat

`Tab` in root search asks Quick AI: the launcher panel becomes a header, a thread, and a composer (750 × 475, larger by drag). Follow-ups stay in the chat. `⌘P` lists recent chats in the same panel. `⌘J` moves the chat to the AI Chat window: a normal, resizable window with a multi-line composer, a chat list (`⌃⌘S`), and find (`⌘F`). Both views share one store of settings and chat history. Math, conversions, dates, and system facts never reach a model: in root search they answer in place, and in a chat they show as a "Local answer" that is never a turn of the chat.

## Type to Click

A second global hotkey (Settings › General, where it can also be cleared) opens a keyboard-only overlay over the frontmost app. The controller walks the app's Accessibility tree and its full menu hierarchy, then draws a label on each visible control and menu-bar item, one panel per display so mixed-Retina setups line up. Typing fuzzy-searches labels, roles, and menu paths; the map narrows with the query. Return acts on the best match with the element's semantic action, falling back to a guarded click at its midpoint; Command, Shift, or Option with Return sends a modified click, Control with Return a right click. Two continuation modes: "Stay open and rescan" keeps the overlay up after each action, and when a native menu opens its items become the next target map with labels drawn above the menu; "Dismiss after one action" closes after one click. Keys are intercepted by a CGEvent tap, so Quick Launch never becomes the active app and the controlled app keeps its menus and field focus.

## Agent Watch

`AgentSessionWatcher` keeps the Mac awake while Claude Code or Codex is working. Agent hooks write one small JSON file per session into `~/Library/Application Support/Quick Launch/AgentSessions` (the old Tuna Companion folder is watched too). The watcher uses one file-system event source per folder, no polling, and sweeps stale files after 12 hours. Live sessions drive the Caffeinate Agent Watch state and its Status row.

## Interaction contract

The app stays running as a small menu-bar process.

- The main global hotkey opens one search field.
- Typing filters items across the enabled catalogs in one ranked list.
- The launcher learns: the text typed when an item is chosen ranks that item first for the same text next time, per catalog, with a 14-day decay. Learning is local, bounded, optional, and can be forgotten.
- The launcher keeps a local interaction journal: a bounded review log of outcomes — choices, searches typed and dropped, retries of the same query, action and AI failures or cancellations, successful and stopped command actions, and hotkey runs. It stores item identifiers, category codes, and a keyed HMAC-SHA256 digest of the folded query under a random 32-byte key generated on first use and kept owner-only beside the journal; repeats correlate on this Mac and the digest cannot be recomputed without that file. It never stores the query text, an exact query length (only a coarse band), or any clipboard, snippet, chat, selection, file, or AI answer content, and an identifier that could carry content is digested too. The digest is one-way, not a secret store: a short query stays guessable by brute force from the digest plus the key. Settings › General › Learning & Review shows its status, lets the user mark a recorded choice as the wrong one (explicit, reversible, never fed into ranking), export it as JSON Lines or Markdown, reveal the file, or clear it. On by default: 30 days, 2 000 events, `0600`, no network. Turning it off stops new recording and keeps what is already there until it is cleared or ages out.
- Escape steps back one layer: a `⌘K` form or pane, a chooser, Recent Chats, a running answer (what arrived is kept), typed text, an attachment, Quick AI (back to root search, the chat kept), a local answer, a mode, a catalog. At root search it closes the panel. In AI Chat, Escape closes the `⌘K` palette or a chooser, stops a running answer, and closes the chat list and the find bar, but never clears typed text or closes the window; `⌘W` closes it. In the Translator it closes the language list, then clears the text, then closes the window.
- Backspace on an empty field steps back the same way but never closes the panel. Within the Keep my place interval (10 seconds by default) a reopen lands where the user left off; after it, reopening starts at the root.
- In root search and the catalogs a footer shows the keys that work now; rows show their global hotkey. Quick AI and AI Chat have no footer: the composer names what Return does, and a list or chooser over the composer names its own keys.
- `Command+Shift+V` opens Clipboard History directly.
- Arrows navigate. Return runs or pastes. `Command+C` copies a selected catalog item.
- App filtering uses a startup cache and no polling or AI call.
- Every app can have an editable alias and optional global hotkey in Settings.
- An alias narrows directly to an item or command.
- Return runs the default action.
- Command-K shows keyboard-accessible actions for the selected item, including editing and guarded deletion of local snippets.
- Backspace on an empty catalogue search returns to root; inactive nested catalogue state clears after 15 seconds.
- Any item or command can have its own global hotkey.
- A direct global hotkey runs without opening the search panel when no choice or result is required.
- A result that needs review opens in the panel. The input regains focus when the result finishes.
- Result routing uses two standard actions: copy to the clipboard or paste into the previous app.
- The panel opens on the display that contains the mouse pointer.

## Catalogs

| Catalog | Default action | Direct use |
|---|---|---|
| Apps | Launch | Alias or assigned hotkey |
| Snippets | Paste into the previous app | Alias or assigned hotkey |
| Clipboard | Paste into the previous app | Open catalog, choose item |
| Translate | Show or replace translation | Language action or assigned hotkey |
| Quick Links | Open in the chosen browser | Alias or assigned hotkey |
| Quick AI | Ask in a chat; paste or copy the answer | `Tab`, the Ask AI row, a prompt alias, or an assigned hotkey |
| Chats | Continue the chat in Quick AI; `⌘J` opens it in AI Chat | Enter the catalog, or `⌘P` for Recent Chats inside Quick AI |
| AI Chat | Open the chat window on the last chat, or a new one | The "AI Chat" command, `⌘J` on Quick AI, or the menu-bar menu |
| Windows | Apply a window layout | Alias or assigned hotkey |
| Vault Search | Show a cited current, reconciliation, history, or portfolio result | Enter the catalog, choose a mode, type the project and question |
| Colors | Paste the picked colour into the previous app | Run Pick Color from Screen, or open the catalog and choose a colour |

Catalogs share one item and action model. Each action owns its title, aliases, optional hotkey, input rule, output rule, and handler. AI providers remain behind Quick AI and Translate. Deterministic commands do not go through a model.

Pi can use its own configured tools and skills. OpenAI-compatible providers
share Quick Launch's own tool loop: read-only tools for memory (`recall`), the
vault (the Vault Search SSH lane), skills (`~/.claude/skills`), and the web
(SearXNG), at most six rounds and 30 seconds of tool time per answer, each tool
switchable per chat in `⌘K` › Tools. The Claude Code CLI provider gets no tools.
Capture to Memory is the one write, and only the user runs it. There is no
on-device Apple model and no MCP configuration.

## Local catalogs

Snippets and Quick Links are owned by Quick Launch and stored in an owner-only
catalog; a surviving legacy catalog is imported once. Clipboard history keeps
text, images, rich text, and file URLs. Caffeinate, screenshot capture, screen
OCR, and the screenshot text index are in; general Finder file search stays out
unless the scope changes.

## Privacy

- Selected-text access uses macOS Accessibility. It does not record the screen.
- The interaction journal is optional and local: outcome rows only, bounded by retention and a hard event cap, written owner-only to `~/Library/Application Support/Quick Launch/interaction-journal.json`. The input field — which also carries AI prompts, and whose Ask AI row is digested like any other accepted row — is reduced to an HMAC-SHA256 digest (12 hex characters, `v2:`-prefixed) under a random per-install key kept owner-only in `interaction-journal-key`, before it is written, so no typed text reaches the file; only a coarse size band records how long it was. An identifier that could carry content is digested the same way, including the typed-URL row, whose launcher identity is a stable keyless FNV-1a hash that this journal re-keys under its own HMAC key. The digest is one-way, not a secret store. The journal is review evidence and never a ranking input.
- Clipboard history is optional, local, bounded, and easy to clear.
- Snippet and clipboard values never appear in diagnostics.
- A question to an API or CLI provider sends more than the typed text: every earlier question and answer of the chat, the app's instruction, a saved command's or an assistant's instructions and context skills, any Add Context or selected text that went with this or an earlier question, web search snippets, and the text of a page whose address was typed. An OpenAI-compatible provider also receives what the memory, vault, skill, and web tools return; the Claude Code CLI provider runs with no tools. Tools are switchable per chat (`⌘K` › Tools) and for new chats (Settings › General › Chat). Screenshots go to the vision model chosen in Settings.
- Chat history is optional, local, owner-only, and bounded (100 chats on a new install; pinned chats are kept). A question is saved with its Add Context or selected text in front of it. A tool call leaves only its one-line record and its sources in the chat. Web search snippets, page text, and what a tool returned are not saved as chat turns; a submitted screenshot's bytes are archived with the chat as a source, like any other attachment.
- Continue in pi writes the chat's text to an owner-only folder and hands it to pi, which sends it to pi's own model.
- App, link, snippet, clipboard, colour, and window commands remain local.
- The colour picker uses AppKit's colour sampler. It reads one pixel value, needs no screen recording permission, and stores numbers rather than images.
- Web search uses Tristan's SSH-only SearXNG stack. Ranked titles, links, and snippets are external data, never executable instructions.
- Vault Search uses the same SSH-only VPS. Current, reconciliation, history, and portfolio queries stay inside the VPS and Neon read layer; the result includes source paths, freshness, and root counts. Broad semantic Find remains a separate path with its own provider-egress policy.
- Quick Launch keeps no background screen history. Its own Screen History collector and catalog were retired on 2026-09-26; `screenctx` (memory-screenctx) is the House's one screen-history collector.
- App discovery happens once at launch. When Clipboard History is enabled, one
  lightweight pasteboard change-count check runs each second.
- Network work starts only after the user runs an action. Each search and model answer has a hard time limit.
