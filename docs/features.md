# Quick Launch — Feature Reference

Quick Launch is a private, keyboard-first macOS launcher and instant AI
overlay. This document is the detailed reference for current behavior; the
[README](../README.md) is the short version.

Scope boundary: Quick Launch is not an autonomous desktop agent. AI Chat is one
conversation window over the same providers and tools. There is no autonomy, no
project management, no automations, and no file changes; those belong to pi.

## Launcher and search

- One ranked root search across apps, folders, commands, snippets, quick links,
  catalog roots, saved actions, and the Ask AI row.
- Fuzzy matching narrows as you type. An exact name, prefix, alias, or learned
  abbreviation wins over the fallback row.
- `Return` runs the highlighted row. Arrow keys navigate; `Command+Shift+V`
  opens Clipboard History directly.
- The launcher learns from use: the text typed when an item is chosen ranks that
  item first for the same text next time, per catalog, with a 14-day decay.
  Learning is local, bounded, optional, and can be forgotten.
- An empty search can show most-used items. The launcher opens on the display
  that contains the mouse pointer, with its input row on the centre line.
- Escape steps back one layer at a time; at root search it closes the launcher.
  Backspace on an empty field steps back the same way but never closes it.
- Within the **Keep my place** interval (10 seconds by default) a reopen lands
  where you left off; after it, reopening starts at the root.
- Root search and the catalogs show a footer with the keys that work right now.
  Rows with a global hotkey show a badge. Quick AI and AI Chat have no footer:
  the composer names what `Return` does.

### Fallback commands

Unmatched root-search text runs the first Fallback Command on `Return`. Ask AI
heads the list out of the box; the list is reordered and edited in
**Settings › General**. The search row names whatever `Return` will actually
run.

## Local answers

Math, unit conversions, dates, and city times are computed on this Mac and
never reach a model.

- `sqrt(2)^2`, `12 km in miles`, `72f to c`, `3 days from now`,
  `days until 2026-12-25`, `time in tokyo`.
- In root search the answer is the top row as you type; `Return` copies it,
  `Command+Return` pastes. `Tab` or the Ask AI row answers it in place under the
  input row and never opens Quick AI.
- Asked from a chat composer, a local answer stays in the chat as its own answer
  with "Local answer" in the header, never a turn of the chat.
- A typed address such as `apple.com` gets an Open row.

## Quick AI

`Tab` opens Quick AI and sends whatever you typed in the same gesture (an empty
field opens it empty), from any search and whatever the fallback list holds. The
panel becomes a chat surface with a header, a thread, and a composer.

- Your turns appear as pills on the right; answers as prose on the left, with a
  web-search or thinking status line.
- `Return` on an answer pastes it into the previous app, or copies it, per
  **Settings › General › Quick AI and AI Chat**. Typing asks a follow-up.
  `Return` while an answer streams queues the follow-up to send when the answer
  ends.
- `Escape` stops a stream and keeps what arrived as the answer; otherwise it
  returns to root search with the thread kept, and a second `Escape` closes the
  window.
- A provider error stays under its question with Retry.
- Keys: `Command+N` new chat, `Command+R` ask the last question again,
  `Shift+Command+R` regenerate on another model, `Command+Shift+O` change model,
  `Shift+Command+C` copy answer, `Option+Command+C` copy the whole chat,
  `Command+J` open in AI Chat, `Command+P` recent chats, `Command+[` and
  `Command+]` flip between recent chats.
- The window is resizable by dragging its edges, and keeps the size across opens
  and relaunches. **Reset Quick AI Size** returns it to its default.
- The empty surface shows three quiet hints: `@` for context, `Command+P` for
  recent chats, `Shift+Command+O` for the model.
- Long questions over ten lines collapse with **Show more**; answers always show
  in full.
- The thread follows new text only while you are at the bottom. A **Latest**
  chip, or `Command+Down`, takes you back.
- Command output and a Vault Search use the same surface, naming the command or
  "Vault Search · mode" where the model would be, and never join a chat.

### Recent chats

`Command+P` opens Recent Chats in the same window: one column the composer
searches by title and message text. `Return` opens the highlighted chat,
`Escape` clears the search and then returns to the thread. The Chats catalog in
root search lists the same chats with the same row actions. Pinned chats are
marked and are never pruned.

### Clarifying questions

**Let the model ask clarifying questions** (off by default) decides whether the
model may pause with a multiple-choice card.

## AI Chat

`Command+J` on Quick AI, or the header's **Open in AI Chat** button, moves the
chat to the AI Chat window with its model, tools, typed text, and attachments.
The launcher closes, so one chat is open in one window.

- AI Chat is a normal, resizable window that appears in `Command+Tab`, the Dock,
  and Mission Control while it is open, and stays while you use the launcher.
- It shares the same thread and composer as Quick AI, with a multi-line composer
  (`Return` sends, `Shift+Return` a new line).
- Find in chat (`Command+F`): `Return` or `Command+G` next, `Shift+Return` or
  `Shift+Command+G` previous, Escape closes. A match in a folded question opens
  it.
- A chat list slides in with `Control+Command+S` (or `Command+P`): a search
  field, Pinned then Recent, arrow keys and `Return`, `Command+K` on the
  highlighted row for Pin, Rename, and Delete, and `Command+1`…`Command+9` to
  jump.
- `Command+K` › **Keep on Top** floats the window above other windows, and is
  remembered.
- Both views share one store of settings and chat history. A chat asked in one
  window is in the other's list at once; a rename, pin, or delete made in one is
  not undone by the other.
- Escape closes the find bar, the chat list, and any layer over the composer,
  never the window; `Command+W` closes it. `Return` on an empty composer copies
  the answer, since the window has no app behind it to paste into.

## Saved actions and assistants

- A saved AI command runs by fuzzy slash alias (`/improve`, `/grammar`,
  `/tldr`, `/translate`), by name from `Command+K`, or by a global hotkey.
  Aliases are fuzzy, so `/eml` finds `/email`.
- A saved command with **Instructions** is an assistant. Its alias alone, a
  `Command+K` row, or its hotkey with nothing selected starts or switches the
  Quick AI chat to it and sends nothing. Its instructions and context skills
  lead the system message, its tools become the chat's tool set, and a pinned
  provider and model apply.
- Two assistants ship by default: **Vault researcher** (vault, memory, and
  tasks tools; cites sources) and **STE editor** (Simplified Technical English
  rules, no tools).
- **Settings › AI Commands** sets a command's name, fuzzy alias, prompt, output
  behavior, optional global hotkey, and optional provider and model. The
  **Assistant** card adds Instructions, Tools, and Context skills read from
  `~/.claude/skills`.
- A saved action's prompt takes `{selection}` where the text lands. Rewrite
  actions preview first and never auto-write: use **Replace Selection** (writes
  back to the original captured selection, verified against the current one),
  **Copy**, or paste.

## Tools inside the chat

An OpenAI-compatible model can call read-only tools that Quick Launch runs
itself, each through a CLI with an argv array (no shell) and a timeout:

| Tool | Reads |
|---|---|
| `recall_memory(query)` | notes under `~/memory` |
| `recall_captures_today()` | today's captures |
| `recall_tasks_today()` | due-today, overdue, and in-progress tasks |
| `recall_open_tasks()` | the complete open backlog |
| `search_vault(query, mode)` | the Vault Search lane: current, reconcile, history, or portfolio |
| `read_skill(name)` | a `SKILL.md` from the skills folder, capped at 12,000 characters |
| `search_web(query)` | the self-hosted search service |

- The model is told to use memory and the vault only when you ask about your own
  notes, projects, clients, decisions, or files, and a skill when you name one
  or ask how you do something.
- An answer may use six tool rounds and 30 seconds of tool time; after that the
  model is asked to answer with what it has.
- Every call leaves a saved line in the thread, and source-backed results list
  their sources. **Open Source** (`Command+O`) opens one.
- `Command+K` › **Tools** (`Option+Command+K`) turns each tool on or off per
  chat. New chats start on the defaults in **Settings › General › Chat**.
- **Capture to Memory** (`Option+Command+M`) sends the answer on screen to
  `recall remember`. It is the one write, and only you can run it.
- Long chats are held to a budget from the model's context window: older tool
  results go first, then old turns, never the first or current question.

### Continue in pi

**Continue in pi** (`Option+Command+P`, or `Command+K`) writes the thread as
Markdown to an owner-only handoff folder, starts a detached tmux session in your
home folder running `pi @<file>`, and opens a new terminal window attached to
it. Needs `tmux` and `pi` on `PATH`. Quick Launch does not stop the session.

## Attachments

Quick AI and AI Chat take files, links, pictures, and selected text as reference
material for a question.

- **Attach** (the plus control, `Shift+Command+A`, `Command+K` → Attach…, or `@`
  in the composer) lists Files… and Link… first, then selected text and screen
  captures. `Shift+Command+S` opens the smaller capture-only chooser.
  `Shift+Command+D` captures the display under the pointer.
- Selected text captured from the previous app appears as a chip; **Preview**
  (`Option+Command+I`) shows the complete passage.
- Supported: PDF; DOCX, RTF/RTFD and ODT; PPTX; XLSX; HTML; plain text,
  Markdown, and code; web pages; and images. Pages, Numbers, Keynote, archives,
  audio, video, and folders are refused with a reason. A scanned PDF is read
  with on-device OCR.
- Limits: 10 attachments and 6 images a question; 50 MB a document, 20 MB an
  image, 5 MB a text file. A request carries at most 200,000 characters per
  source and 400,000 in total, reduced to the model's context budget.
- **What is stored.** Submitted sources keep their original bytes, normalized
  inference images, extraction and location data, hashes, and source metadata in
  an owner-only Application Support folder. A structured record per chat refers
  to those immutable blobs. Deletion is explicit and reference-aware. Original
  user files are never deleted.

## Translator

The Translator window (`Shift+Command+T`, or the Translate item) opens with
selected text or a fresh input field.

- Translation waits for a 600 ms pause; typing cancels the previous response.
- The target and language pair stay as you chose them. `Command+T` chooses the
  target; `Command+S` swaps the pair and moves the completed translation into
  the input.
- `Command+Return` copies and closes, `Shift+Command+Return` pastes back,
  `Shift+Command+V` uses the clipboard. Chinese output includes pinyin.
- Escape closes the language list, then clears the text, then closes the window.
  Committed translations are kept locally (500).
- `Shift+Return` in the launcher translates one-shot; `/zh` and `/translate`
  act on selected text.

## Screenshots and captures

- **Screen Awareness**: Send Focused Window to AI (a double tap of the right
  `Command` key from anywhere) attaches a screenshot plus the app name, window
  title, selection, readable text, and page URL. Send Screen, Send Screen Area,
  and Send Selected Text cover the narrower cases. The attachment card says what
  was included.
- The **Screenshots** catalog lists captures plus saved files with a preview
  pane; search by name, date words (`today`, `7d`), or the text inside the image
  (on-device OCR). Attach, copy image, paste image, Quick Look, pin, reveal,
  copy path, or trash.
- **Paste Latest Screenshot** pastes the newest file straight into the previous
  app; **Attach Latest Screenshot** joins the next question.
- A screenshot attached to a question is archived with that chat as a submitted
  source, like any other attachment, and stays available to the thread for
  follow-ups. A chosen vision model decides where screenshots go.

## Text from screen

**Copy Text from Screen Area** and **Paste Text from Screen Area** read text in
a dragged region on this Mac with Vision and put it on the clipboard. The
captured pixels are not saved. A line-break preference is in
**Settings › Clipboard & Capture**.

## Type to Click

A global hotkey (in **Settings › General**) puts a label on every clickable
control in the frontmost app and its menu bar, found through macOS
Accessibility.

- Type part of a label, role, or menu path to narrow the map; `Return` clicks
  the best match.
- `Command`, `Shift`, or `Option` with `Return` sends a modified click;
  `Control+Return` a right click.
- **Stay open and rescan** keeps the overlay up so you can chain steps; an
  opened native menu becomes the next target map. **Dismiss after one action**
  closes after one click.
- The overlay never activates Quick Launch, so menus and field focus stay with
  the app you are driving.

## Clipboard History

`Command+Shift+V` opens a bounded, local, clearable history of text, images,
rich text, and files.

- `Command+Shift+P` pins to top, `Command+Shift+N` saves as a snippet,
  `Command+Shift+L` saves as a Quick Link, `Control+X` deletes.
- It honours concealed and transient pasteboard markers. Copies of AI answers
  are marked transient, so Clipboard History skips them.
- Payloads are bounded and owner-only; it can be turned off or cleared in
  **Settings › Clipboard & Capture**.

## Snippets and Quicklinks

Private local snippets and Quicklinks with aliases, optional per-item global
hotkeys, and pin to top (`Command+Shift+P`).

- Stored in an owner-only local catalog, not in app settings. A surviving
  legacy catalog is imported once.
- `Command+K` on a snippet or Quicklink gives it a search alias or hotkey, or
  offers Paste, Copy, or Copy & Paste. Paste targets the topmost external window
  directly behind Quick Launch.

## Emoji and symbols

The Emoji & Symbols catalog is a grid: Frequently Used first, emoji, flags,
arrows, math, currency, punctuation, and key symbols, searched by name or plain
words (`fire`, `thumbs up`, `command`). `Return` pastes, `Command+Return`
copies. One skin tone setting applies to every emoji that takes one.

## Colors

Pick Color from Screen magnifies any pixel on any display with the system loupe
(no screen recording permission), copies it in your chosen notation, and closes.
The pick is kept in the local Colors catalog.

- Rows show a swatch with Hex, RGB, HSL, HSB, and a colour name. `Command+1`…
  `Command+4` copy the other notations, `Command+Shift+P` pins, `Control+X`
  deletes.
- **Pick Color and Paste** sends it straight to the app behind the panel.

## Window management

The full set: Maximize, Almost Maximize, Maximize Height/Width, Reasonable Size,
Center, Left/Center/Right/Top/Bottom Half, four Quarters, Thirds and Two Thirds,
Fourths, six Sixths, Make Smaller/Larger, Move Left/Right/Up/Down, Restore,
Toggle Fullscreen, and Move to Next/Previous Display. Left and Right Half cycle
half → two thirds → third on repeat.

Type a layout name such as `left half`, `center third`, or `third fourth` and
press `Return` to resize the window that was active immediately before Quick
Launch. Every command takes an alias and a hotkey in **Settings › Items ›
Windows**.

## Caffeinate and Agent Watch

- A native Caffeinate toggle keeps the Mac awake while Quick Launch is running,
  with power assertions and a battery cutoff. Toggle it by right-clicking the
  menu-bar icon or from the Caffeinate catalog.
- **Caffeinate Until…** accepts a time (`17:30`, `5:30pm`) or a duration
  (`90m`, `2h`).
- **Agent Watch** keeps the Mac awake while a supported agent turn is running by
  watching small JSON files that agent hooks write. Point the hooks at the
  bundled `scripts/quick-launch-agent-event` helper; the old companion folder is
  watched too.

## Vault Search

A catalog backed by the private VPS and a read layer: Current Project, Reconcile
Changes, Project History, and Across Projects.

- Structured modes make one read-only call with no model-provider egress, show
  freshness and source paths, refuse future evidence, and ask for project scope
  when a name is ambiguous.

## Screen History

A local, search-only catalog over an owned SQLite FTS store and a separate
existing database, with time, app, and site filters, stable source-labelled
rows, image and OCR previews, surrounding timelines, and no AI or remote
fallback.

- Every row is labelled by source. It never falls back to a model, web search,
  Vault Search, or telemetry.
- This beta hard-locks owned capture. Capture is off by default, switched on in
  its own Settings tab, stored only on this Mac, and stays locked until its
  privacy review and soak test pass. Browser capture is not available.

## Learning and the interaction journal

The app keeps a bounded local review log of launcher and AI outcomes: choices,
searches you typed and dropped, retries of the same query, action and AI
failures or cancellations, successful command actions, and hotkey runs.

- It stores item identifiers, category codes, and a keyed one-way digest of a
  typed query, never the query text and never any clipboard, snippet, chat,
  selection, file, or answer content.
- The digest is HMAC-SHA256 under a random 32-byte key this Mac generates on
  first use and stores owner-only. Repeats still correlate locally, and the
  digest means nothing without that file. An identifier that could carry content
  is digested instead.
- This is not a secret store: a short query can still be guessed by brute force
  if someone has the key file, and no search field is a password box.
- **Settings › General › Learning & Review** shows the event count, size, and
  last event; lets you mark a recorded choice as the wrong one (reversible,
  never fed into ranking); exports JSON Lines or Markdown; reveals the file; or
  clears it.
- On by default: 30 days, 2,000 events, owner-only, nothing sent anywhere.
  Turning it off stops new recording and keeps what is already there until you
  clear it or it ages out.

## Keyboard and interaction contract

- The main global hotkey opens one search field. The main launcher shortcut, and
  every other global hotkey, is editable.
- A shortcut already owned by macOS shows a conflict message instead of failing
  silently. Replace Selection uses `Option+Command+V`: `Shift+Command+V` is
  Clipboard History's global hotkey.
- **Settings › Keyboard Shortcuts** lists every remappable in-app key and
  records a replacement with the same recorder; recording the built-in key is a
  reset. A collision with a fixed key, another action's key, or a global hotkey
  is refused and explained.
- Arrows navigate. `Return` runs or pastes. `Command+C` copies.
- App filtering uses a startup cache and no polling or AI call.
- Any app, item, or command can have an editable alias and optional global
  hotkey. A direct global hotkey runs without opening the search panel when no
  choice or result is required.
- Result routing uses two actions: copy to the clipboard or paste into the
  previous app.

### Catalog reference

| Catalog | Default action | Direct use |
|---|---|---|
| Apps | Launch | Alias or assigned hotkey |
| Snippets | Paste into the previous app | Alias or assigned hotkey |
| Clipboard | Paste into the previous app | Open catalog, choose item |
| Translate | Show or replace translation | Language action or assigned hotkey |
| Quick Links | Open in the chosen browser | Alias or assigned hotkey |
| Quick AI | Ask in a chat; paste or copy the answer | `Tab`, the Ask AI row, a prompt alias, or an assigned hotkey |
| Chats | Continue the chat in Quick AI; `Command+J` opens it in AI Chat | Enter the catalog, or `Command+P` inside Quick AI |
| AI Chat | Open the chat window | The AI Chat command, `Command+J` on Quick AI, or the menu-bar menu |
| Windows | Apply a window layout | Alias or assigned hotkey |
| Vault Search | Show a cited result | Enter the catalog, choose a mode, type the project and question |
| Screen History | Open the surrounding local timeline | Enter the catalog, type a memory, add filters |
| Colors | Paste the picked colour into the previous app | Run Pick Color from Screen, or open the catalog |
| Emoji | Paste the symbol | Open the catalog and type a name |
| Screenshots | Attach or act on a capture | Open the catalog and type a name |

## Models and providers

- Providers are swappable: local OpenAI-compatible servers, hosted
  OpenAI-compatible APIs, and CLI subscription providers, plus a provider that
  uses the installed pi configuration.
- **Settings › Models** manages every provider and model: enable or disable each
  model, group by provider, and sort by brand, alphabetically, speed,
  intelligence, or context window. A disabled model disappears from every picker.
- Where a model supports reasoning effort, its row and the AI Commands editor
  set it, and the choice follows you between models that take one.
- API keys are stored in the macOS Keychain and are not synced through iCloud.
  Provider settings, model choices, and actions use local `UserDefaults`.
- Local model discovery scans the local server's model folder without starting
  it.

## Privacy boundary

- Math and local providers stay local. Cloud providers receive everything a
  question sends: the question, the allowed conversation context, the app's
  instruction, a saved command's or assistant's instructions, selected source
  passages and images, and any permitted tool results.
- Source-only turns do not silently widen to unrelated history, memory, vault,
  web, or skills.
- The memory and skill tools read local files only. The vault tool sends its
  query over SSH to the private VPS. What a tool returns goes to the chat's
  model while it writes that answer.
- Chat history and source blobs are local and owner-only. Submitted material is
  saved before provider execution; a save failure keeps the draft and blocks
  Send.
- Clipboard History is local, optional, deduplicated, and bounded. It keeps the
  full copy so a later paste restores the original representation.
- Snippet and Quicklink values are stored owner-only and are not logged or copied
  into Quick Launch settings.
- Picked colours are stored as numbers, not pixels or screenshots.
- Text read from a screen area is recognised on this Mac and goes to the
  clipboard; the pixels are not saved.
- Selected-text actions use macOS Accessibility only to read or replace the
  current selection. They do not record the screen.
- The interaction journal is local, bounded, and content-free, as described
  above.
- The app has no analytics and sends nothing about your use anywhere.

## Architecture

```text
OverlayView (launcher panel)
  → QuickViewModel
      → QuickStore: settings and chat history, shared with AI Chat
      → cached local application catalogue
      → owner-only local snippet and Quicklink catalog
      → bounded local clipboard history
      → bounded search-service snippet bundle
      → OpenAI-compatible streaming service
      → one-shot CLI service

AIChatWindowView (AI Chat window)
  → AIChatWindowModel: chat list, find in chat, Keep on Top, keys
      → the same QuickStore and services as the launcher
```

The implementation uses SwiftUI, AppKit, `URLSession`, `Process`, and the macOS
Security framework. CLI prompts are sent over standard input and are never
interpolated into a shell command.

## Performance contract

- The app catalogue is read once at launch. Typing never scans the file system.
- The panel resizes from state changes. Clipboard History uses one lightweight
  pasteboard change-count check per second when enabled. No other idle poll
  runs.
- Provider startup, model discovery, update checks, and web requests run only
  after an explicit action.
- App discovery and 100 fuzzy filters each have a 250 ms regression gate.
- Web search uses snippets rather than full-page extraction and has an
  eight-second retrieval ceiling.
- A silent web-answer model is stopped after 15 seconds. Linked results appear
  instead of an endless spinner.
- An answer's tool loop has six rounds and 30 seconds of tool time; a stuck tool
  is cut at the budget and the model answers with what it has.

## Not in the core build

Finder file actions, autonomous file changes, voice input, and a larger chat
workspace are deferred. Explicit clipboard image attachments are supported.
Quick Launch does not watch the screen on its own: the only continuous capture
is the opt-in owned Screen History capture described above.

## Removed

- **On-device Apple model support (2026-08-22).** The upstream fork shipped a
  helper process that exposed Apple's Foundation Model over localhost, plus
  MCP server configuration for that route. Apple Intelligence is not available
  to this project, so the helper, its dependency, the managed provider, and the
  MCP tab are gone. Settings saved by earlier builds load unchanged. The
  OpenAI-compatible client remains the inference path.
