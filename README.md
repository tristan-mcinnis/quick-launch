# Quick Launch

**A lightweight, Spotlight-style launcher with Quick AI for macOS.**

The focused launcher scope is documented in [docs/product-scope.md](docs/product-scope.md).

Press `Option+Space` and type. `Return` runs the highlighted app, command, or
saved action. `Tab` asks Quick AI: the launcher becomes a chat thread with a
composer, and follow-ups stay in that chat. `⌘J` moves the chat to AI Chat, one
conversation window over the same providers and tools. No autonomy, no
projects, no automations, no file changes; those belong to pi.

Quick Launch runs swappable local, API, and subscription-backed models. It was
forked from the original `apfel-quick` project; the Apple on-device path that
fork was built around was removed on 2026-08-22 (see "Removed" below).

## Core features

- Global, configurable hotkey and small floating panel
- Fuzzy application launcher with live rows, aliases, optional per-app hotkeys, arrow navigation, and Return to open
- Learns from your choices: the text you typed when you picked an item ranks that item first next time (`cla` → Claude), with a 14-day decay so old favourites fade; most-used items show on an empty search; local only, one toggle and a Forget button
- Local interaction journal: a bounded review log of launcher and AI *outcomes* — choices, searches you typed and dropped, retries of the same query, action and AI failures or cancellations, successful command actions, and hotkey runs. It stores item identifiers, category codes, and a *keyed* one-way digest of a typed query, never the query text and never any clipboard, snippet, chat, selection, file, or answer content. The digest is HMAC-SHA256 under a random 32-byte key this Mac generates on first use (`interaction-journal-key`, owner-only), so repeats still correlate locally and the digest means nothing without that file; an identifier that could carry content (a typed URL, a window title) is digested instead. A query's exact length is never stored — only a coarse band. Note what that digest does and does not protect: the typed text is one-way, but a *short* query can still be guessed by brute force if someone has the key file, and no search field is a password box. Settings › General › Learning & Review shows the event count, size, and last event, lets you mark a recorded choice as the wrong one (reversible, never fed into ranking), export JSON Lines or Markdown through the normal save panel, reveal the file, or clear it. On by default, 30 days and 2 000 events, `0600`, nothing sent anywhere; turning it off stops new recording and keeps what is already there until you clear it
- One ranked root search across apps, folders, commands, snippets, quick links, catalog roots, and the Ask AI row
- Return runs the highlighted row. Ask AI is a row: one word keeps the launcher first (`weather` opens Weather), two or more words or a question put Ask AI first, and an exact name, prefix, alias, or learned abbreviation still wins. `Tab` opens Quick AI and sends whatever you typed in the same gesture (an empty field opens it empty), from any search and whatever the fallback list holds; the Tab hint is hideable in Settings › General › Quick AI and AI Chat. When nothing matches, Return runs the first of your Fallback Commands, Ask AI by default. Ask AI learns from use and takes a pin, alias, or hotkey like any row
- Answers as you type: math, unit conversions (`12 km in miles`, `72f to c`), dates (`3 days from now`, `days until 2026-12-25`), and city times (`time in tokyo`) are the top row; Return copies, `⌘↩` pastes. `Tab` or the Ask AI row on one of these answers it right there, under the input row, and never opens Quick AI. A typed address (`apple.com`) gets an Open row
- Folders catalog: the user folders plus any you add in Settings, opened in Finder (or the existing window fronted); `dl` → Downloads, `dk` → Desktop out of the box; alias, hotkey, pin, `⌘↩` reveal, `⌘⇧C` copy path
- `⌘K` on a running app: Hide, Quit, Relaunch, Force Quit
- Commands also hold quick toggles (dark mode, lock screen, empty trash, eject all, hidden files, desktop icons), 45 System Settings panes, Pick Color from Screen, Copy Text from Screen Area and Paste Text from Screen Area (local OCR, with a line-break preference), Paste as Plain Text, and Clean Link (`⌘⇧U` on tracked links)
- Raycast-style footer in root search and the catalogs with the keys that work right now, and Sol-style hotkey badges on rows that have a global hotkey. Quick AI and AI Chat have no footer: the composer names what Return does
- Escape steps back one layer at a time (a `⌘K` pane, a chooser, a running answer, typed text, an attachment, Quick AI, a mode, a catalog) and closes the launcher at root search; Backspace on an empty field steps back too but never closes the launcher; after the Keep my place interval (10 seconds by default) reopening starts at root search
- Finder indexing through the macOS CoreServices application catalog
- Live Tuna Snippets and Quick Links, with aliases, optional per-item global hotkeys, and pin to top (`⌘⇧P`)
- Emoji & Symbols catalog as a grid: Frequently Used first, 1 500+ emoji, flags, arrows, math, currency, punctuation, and key symbols, searched by name or plain words (`fire`, `thumbs up`, `command`), pasted with Return or copied with `⌘↩`; one skin tone setting applies to every emoji that takes one
- Colors: Pick Color from Screen magnifies any pixel on any display with the system loupe (no screen recording permission), copies it in your chosen notation, and closes; the pick is kept in the local Colors catalog. Pick Color and Paste sends it straight to the app behind the panel. Rows show a swatch with Hex, RGB, HSL, HSB, and a colour name; `⌘1`…`⌘4` copy the other notations, `⌘⇧P` pins, `⌃X` deletes
- Translator window (`⇧⌘T`, or the Translate item): source above, translation below, retranslates as you type, arrives with the selected text, auto-detects the direction (CJK → English, else your last target), `⌘T` target language, `⌘S` swap, `⌘↩` copy and close, `⇧⌘↩` paste back, `⇧⌘V` use the clipboard, pinyin under Chinese; Escape closes the language list, then clears the text, then closes the window (`⌘W` closes it at once); committed translations are kept locally (500). `⇧↩` in the launcher still translates one-shot; `/zh` and `/translate` act on selected text
- Caffeinate catalog: toggle, Caffeinate Until… (`17:30`, `5:30pm`, `90m`, `2h`), presets, Agent Watch (stays awake while Claude Code or Codex is working, from hook files), Status; native power assertions, battery cutoff at 20%
- Screenshots catalog: captures plus the saved files with a preview pane; search by name, date words (`today`, `7d`), or the text inside the image (on-device OCR, Vision); attach, copy image, paste image, Quick Look, pin to top, reveal, copy path, trash; Paste Latest Screenshot pastes the newest file straight into the previous app
- Type to Click: a global hotkey (Settings › General) puts a label on every clickable control in the frontmost app and its menu bar, found through macOS Accessibility. Type part of a label, role, or menu path to narrow the map, press Return to click the best match; `⌘`, `⇧`, or `⌥` with Return sends a modified click, `⌃↩` a right click. "Stay open and rescan" keeps the overlay up so you can chain steps, and an opened native menu becomes the next target map with labels drawn over its items; "Dismiss after one action" closes after one click. The overlay never activates Quick Launch, so menus and field focus stay with the app you are driving
- Screen Awareness: Send Focused Window to AI (`⌘⇧S`, or a double tap of right `⌘` from anywhere) attaches a screenshot plus the app name, window title, selection, readable text, and page URL; Send Screen, Send Screen Area, and Send Selected Text cover the narrower cases. The attachment card says what was included
- Clipboard History: pin to top (`⌘⇧P`), save as snippet (`⌘⇧N`) or Quick Link (`⌘⇧L`), delete (`⌃X`)
- Quick Links open in the browser you choose in Settings, or the system default
- Attach Latest Screenshot: the newest file in the macOS screenshots folder joins the next question
- Screenshot attachments: `⌘⇧S` captures the app behind Quick Launch, `⌘⇧D` the display under the pointer, or run the two screenshot commands from any global hotkey; a clipboard image also attaches on open
- One Vision model setting decides where screenshots go; DeepSeek `deepseek-flash` by default, the same model that answers text (the retired `deepseek-v4-flash` and `deepseek-v4-flash-vision-exp` aliases migrate to it), local MLX when chosen; follow-ups keep the screenshot in memory for the thread
- `⌘K` on any row opens a Raycast-style action list with the shortcut beside each action: Return is the primary action, `⌘↩` the secondary (copy, show in Finder, copy link), `⌘⇧↩` copy and paste, `⌘E` edit, `⌘⇧A` alias, `⌘⇧H` hotkey, `⌃X` delete (press twice); the same keys work straight from the list
- Quick AI, Raycast's surface: a 750 × 475 panel replaces the launcher (drag its edges to make it larger; it keeps that size across opens and relaunches, the thread stays one readable centred column, and `⌘K` › Reset Quick AI Size goes back to 750 × 475), with a header (back chevron, the chat title over the model that will answer next), the thread (your turns as pills on the right, answers as prose on the left, a web-search or thinking status line), and a bottom composer whose right edge names what Return does and whose placeholder says what typing will do ("Ask a follow-up…" once a thread exists). An empty surface shows three quiet hints: `@` for context, `⌘P` for recent chats, `⇧⌘O` for the model. Chat titles are the first question as you typed it, tidied up: no saved-prompt `/alias` or "search web" prefix, a capital first letter, cut at a word under 60 characters. Return on an answer pastes it into the previous app (or copies, per Settings › General › Quick AI and AI Chat), typing asks a follow-up, and Return while an answer streams queues that follow-up ("Queued ↩") to send when the answer ends; Escape stops a stream and keeps what arrived as the answer (a queued follow-up stays in the composer, unsent), otherwise returns to root search with the thread kept, and a second Escape closes the window; a provider error stays under its question with Retry; `⌘N` new chat, `⌘R` asks the last question again (after an answer, a stop, or an error), `⇧⌘R` regenerate on another model, Change Model (`⌘⇧O`, or click the model name under the title) switches model mid-thread, Copy Answer (`⇧⌘C`) and Copy Chat (`⌥⌘C`, the whole thread labelled "You:" and the model) copy without closing the window, `⌘J` (or the header's **Open in AI Chat** button) moves the chat to the AI Chat window, `⌘P` (or `⌘H`, the v1.4 key) opens Recent Chats in the same window (one column, `↑↓`, Return opens, Escape back, `⌘K` and the row keys act on the highlighted chat, a pin glyph marks pinned chats), `⌘[`/`⌘]` flip between recent chats. `↑` on an empty composer puts the last question back to edit; PageUp/PageDown and `⌥↑`/`⌥↓` scroll the thread by a page and `⌘↑`/`⌘↓` jump to its ends; the thread follows new text only while you are at the bottom, and a "Latest" chip (or `⌘↓`) takes you back. A command action's output and a Vault Search use the same surface with the command or "Vault Search · mode" named where the model would be, and never join a chat; so does math asked in a chat ("Local answer"), while math in root search answers inline there. The Chats catalog in root search lists the same chats with the same row actions: Return continues one in Quick AI, `⌘J` opens it in AI Chat, then Copy Last Answer, Rename, Pin, and Delete. **Let the model ask clarifying questions** (Settings › General › Quick AI and AI Chat, off by default) decides whether the model may pause with a multiple-choice card
- Tools inside the chat: the model can search your memory (`recall_memory`, `recall_today` through the `recall` CLI), your vault (`search_vault`, the Vault Search SSH lane), and your skills (`read_skill`, a `SKILL.md` from `~/.claude/skills`), beside web search. Each call leaves a line in the thread ("Searched memory: 4 hits", "Searched vault · current: 6 results", "Read skill: costing") that is saved with the answer, and memory and vault hits list their sources under the answer; Open Source (`⌘O`) opens one. `⌘K` › Tools (`⌥⌘K`) turns each tool on or off for the chat, and Capture to Memory (`⌥⌘M`) sends the answer to `recall remember`. See "Tools inside the chat" below
- Code blocks in an answer carry a header strip: the detected language, Copy, and a line-wrap toggle. Long lines scroll sideways by default and wrap only when you turn wrapping on, so pasted output keeps its shape
- Long questions collapse: over ten lines (measured at the thread's width), a question you sent shows its opening lines with **Show more**, and **Collapse** folds it back; both scroll the message's first line to the top. Answers and shorter messages always show in full, and `⇧⌘M` toggles the newest long question (only its control shows the key)
- Add Context: a control left of the composer, or typing `@`, offers Focused Window, Selected Text, Selected Area, and Entire Screen, reusing the Screen Awareness captures. What you attach rides with that message only
- Manage models (Settings › Models): every configured model with its provider, Speed, Intelligence, and Context window, a switch to enable or disable it, Group by Provider, and sorting by Brand, Alphabetically, Speed, Intelligence, or Context Window. A disabled model disappears from every picker in the app. Where a model supports reasoning effort, its row and the AI Commands editor set it, and the choice follows you between the models that take one
- Fallback Commands (Settings › General) decide what unmatched search text runs on Return, added from the app's own catalogs and reordered by drag or keyboard. Ask AI heads the list out of the box, and the search row names whatever Return will actually run
- `⌘K` on a result: save as snippet, search the web for it, copy, or paste it back
- Several screenshots can ride on one question; Backspace drops the newest, the × clears all
- The panel opens with its input row on the centre line of the display under the pointer
- Local, bounded, clearable clipboard history (text, images, rich text, files) on `Command+Shift+V`
- Opens on the display that contains the mouse pointer
- Window management, Raycast's full set: Maximize, Almost Maximize, Maximize Height/Width, Reasonable Size, Center, Left/Center/Right/Top/Bottom Half, four Quarters, Thirds and Two Thirds, Fourths, six Sixths, Make Smaller/Larger, Move Left/Right/Up/Down, Restore, Toggle Fullscreen, Move to Next/Previous Display. Left and Right Half cycle half → two thirds → third on repeat. Every command takes an alias and a hotkey in Settings › Items › Windows
- Native Caffeinate toggle that keeps the Mac awake while Quick Launch is running
- The input row holds Add Context on the left and one ⋯ menu on the right (Actions, the screenshot commands, the model, New Chat, Recent Chats, Open AI Chat, Settings); Return sends, so there is no Send button
- Direct SearXNG web search for explicit searches and time-sensitive questions
- Vault Search catalog backed by the VPS and Neon: Current Project, Reconcile Changes, Project History, and Across Projects. Structured modes make one read-only product call with no model-provider egress, show freshness and source paths, refuse future evidence, and ask for project scope when a name is ambiguous
- Local Screen History catalog over the owned SQLite FTS store and the closed Coast database, with time, app, and site filters, stable source-labelled rows, image and OCR previews, surrounding timelines, and no AI or VPS fallback. This search-only beta hard-locks owned capture. Browser capture remains unavailable in the later capture path.
- Provider and model switcher in the ⋯ menu, listing only the models you have left on
- Recent Chats (`⌘P`) inside the Quick AI window: one column of chats that the composer searches by title and message text, Return opens the highlighted one in the thread, Escape clears the search and then returns to the thread. `⌘P` was free in every key table; `⌘J` became Open in AI Chat, as in Raycast
- AI Chat, one conversation window over the same providers and tools: `⌘J` on Quick AI (or the header's Open in AI Chat button) moves the chat there with its model, tools, typed text, and attachments, and the launcher closes; the "AI Chat" command in root search, or AI Chat in the menu-bar menu, opens it on the last chat, or a new one once the Start New Chat interval has passed. It is a normal, resizable window (860 × 620, 720 × 480 at the least, its frame remembered) that shows in `⌘Tab`, the Dock, and Mission Control while it is open and stays while you use the launcher. The same thread and composer as Quick AI, with a multi-line composer (`↩` sends, `⇧↩` a new line), find in chat (`⌘F`; `↩` or `⌘G` next, `⇧↩` or `⇧⌘G` previous, Escape closes; a match in a folded question opens it), and a chat list that is hidden until `⌘\` (or `⌘P`, or the header's sidebar button) slides it in: a search field, Pinned then Recent, `↑↓` and Return, `⌘K` on the highlighted row for Pin, Rename, and Delete (pressed twice), and `⌘1`…`⌘9` to jump. `⌘K` › Keep on Top floats it above other windows, remembered. Escape closes the find bar, the chat list, and any layer over the composer, never the window (`⌘W` does). Return on an empty composer copies the answer, since the window has no app behind it to paste into. No autonomy, no projects, no automations, no file changes; those belong to pi
- Any OpenAI-compatible endpoint through a custom base URL
- Built-in setup for LM Studio, DeepSeek, Moonshot/Kimi, and OpenAI
- Local LM Studio model detection by scanning `~/.lmstudio/models`, without running `lms` or starting its server
- One-shot Claude Code subscription provider through the installed `claude` CLI
- Pi provider that uses Pi's configured models, extensions, skills, and custom tools
- `/search` retrieval through the existing SSH connection to SearXNG
- Selected-text actions that can show a result or replace the original text
- Command-K keyboard action picker with Paste, Copy, Copy & Paste, Edit, and guarded Delete for snippets, plus fuzzy slash aliases such as `/eml`
- Empty Backspace leaves a nested catalogue, and inactive catalogue views return to the launcher root after 15 seconds
- Editable action names, prompts, aliases, output behavior, provider, model, and global hotkey
- Assistants: a saved AI command with Instructions is an assistant. Its alias alone (`/vault`, then Return), `⌘K` › Change Assistant (`⌥⌘A`), or its hotkey, with nothing selected, starts or switches the Quick AI chat to it: the header reads "Vault researcher · model", its instructions and context skills (read once from `~/.claude/skills`) lead the system message, its tools become the chat's tool set, and its pinned provider and model apply. The alias with text after it (`/vault pricing`), or the alias or hotkey with text selected, still runs its prompt as a one-shot command, in a plain chat of its own. When the new-chat interval starts a fresh chat, the assistant goes along. Two ship by default: Vault researcher (vault and memory tools, cites sources) and STE editor (no tools, ASD-STE100 rules)
- Chat history on this Mac: 100 chats on a new install (20, 50, 100, or 200 in Settings › General › History); pinned chats do not count and are never pruned
- Answer actions are keys and `⌘K` rows, with no Copy or Paste buttons under the answer: Copy Answer (`⇧⌘C`), Copy Chat (`⌥⌘C`, the whole thread), and Paste into Previous App (`⌘↩`)
- Keep my place after closing (Settings › General › History): open the launcher again within 10 seconds (by default) and it is where you left it
- API keys stored in the macOS Keychain and not synced through iCloud
- Deterministic local math, and an optional automatic copy of each Quick AI chat's first answer (on by default; follow-ups and AI Chat never copy on their own, and every copy of an AI answer is marked so Clipboard History skips it)
- Local only: no analytics and no telemetry. The one log the app keeps about your use is the local interaction journal described above, which is bounded, content-free, owner-only, and never leaves this Mac

## Requirements

- macOS 26 or later
- Apple Silicon
- Xcode command-line tools for source builds

Select LM Studio, Pi, Claude Code, or an API provider. Apple Intelligence is
not used.

Optional integrations must already be installed and signed in:

| Provider | Requirement |
|---|---|
| LM Studio | LM Studio. Start its local server before inference. Model discovery scans its model folder without opening the app. |
| Claude Code | `claude` on `PATH` and an active Claude Code sign-in. |
| Pi | `pi` on `PATH` with the desired providers, models, skills, and extensions configured. |
| API providers | A compatible endpoint and, when required, an API key. |
| Web search | SSH access to the existing `vault-vps` SearXNG service. |

Superwhisper's private S1 Mini file is not called directly. Superwhisper does
not expose that model as a general inference endpoint. A GGUF model can be
used after it is imported into a compatible server such as LM Studio.

## Build and run

```bash
git clone https://github.com/tristan-mcinnis/quick-launch.git
cd quick-launch
swift test
make install
```

`make install` builds, signs, and copies the menu-bar app to
`/Applications/Quick Launch.app`. Run `make run` to open the installed app.

Local builds use the stable designated requirement
`com.tristanmcinnis.quick-launch`, allowing macOS Accessibility approval to
survive code changes. The generated `build` directory is excluded from
Spotlight so it does not appear as a second Quick Launch installation.

The build has no helper binaries and one package dependency (`swift-markdown`).

### Screen History evaluation receipts

The Screen History product and security tests append one JSON object per case to
`.build/screen-history-evaluation-receipts/screen-history-evaluation-<run-id>.jsonl`.
Set `SCREEN_HISTORY_EVALUATION_RECEIPT_DIRECTORY` to put the files in another
local directory. Each process uses a new file, so concurrent test runs do not
share an append target.

Receipt schema 1 records the current Screen History store schema version, run
and case IDs, suite, completion result, elapsed milliseconds, measured local
file, statement, tool, and helper counts, a typed network observation, and the
source-root count. A missing count means that the test did not measure it.
`completed` means that the test reached its receipt boundary. Swift Testing is
still the authority for assertion pass or failure. `aborted` means that the
test left scope before that boundary.

The format has no free-form payload fields. It cannot store OCR text, window
titles, domains, file paths, search terms, or queries. The receipt directory and
file use owner-only permissions.

```json
{"case_id":"SH-R01","elapsed_milliseconds":12,"measurements":{"helper_call_count":1,"local_file_count":3,"network":{"mode":"not_measured"},"source_root_count":1,"tool_call_count":0},"recorded_at":"2026-08-25T00:00:00Z","result":"completed","run_id":"00000000-0000-0000-0000-000000000001","schema_version":1,"store_schema_version":7,"suite":"product"}
```

## Use

1. Press `Option+Space`.
2. Type an app name or configured alias such as `spot`. The app list narrows with each key. Use the arrow keys and press `Return` to open the selected app.
3. Type a question, or an action such as `/grammar`, `/tldr`, or `/search`.
4. Press `Tab`, or `Return` on the Ask AI row, to ask Quick AI. The answer streams into the thread. Press Escape to stop it; what arrived stays as the answer.
5. Type in the composer for a follow-up. `Return` while an answer streams queues the follow-up until the answer ends.

The panel appears on the same frame as the hotkey, with no fade. Escape steps
back one layer; at root search it closes the launcher. Open the launcher again
within 10 seconds and it is where you left it; change that interval with
**Keep my place after closing** in **Settings › General › History**. An answer
has no Copy or Paste buttons under it: `Command+Shift+C` copies it,
`Command+Return` pastes it into the previous app, `Option+Command+C` copies the whole chat, and
`Command+K` lists every action. `Command+P` shows your recent chats.

Press `Command+Shift+V` to open Clipboard History directly. Use the arrow keys
and `Return` to paste the selected item into the previous app. Use `Command+C`
to copy the selected item. Clipboard History keeps text, images, rich text, and
files. It is bounded to 50 items by default and by a total byte budget, and you
can turn it off or clear it in **Settings › Clipboard & Capture**. Copies of AI
answers are marked transient, so Clipboard History skips them.

The main launcher also contains Snippets and Quick Links. These catalogs read
the existing Tuna stores live. Highlight an item and press `Command+K` to give
it a search alias or global hotkey, or use the keyboard action pane to Paste,
Copy, or Copy & Paste. Paste targets the topmost external window directly
behind Quick Launch. Quick Launch does not duplicate snippet or link values
into its settings.

Copy a screenshot before opening Quick Launch and it appears as a removable
attachment. Submitting it sends the prompt and image to the Vision model set in
**Settings › Models**: DeepSeek `deepseek-flash` by default, or the local MLX
server at `127.0.0.1:8078/v1` when you choose it. An empty prompt asks for a
useful description. Screenshot bytes stay in memory for the thread, so its
follow-ups send them again, and are never written to history or settings.

Type a layout name such as `left half`, `center third`, or `third fourth` and
press Return to resize the window that was active immediately before Quick
Launch. Open the highlighted command with `Command+K` to assign a shorter alias
or global hotkey. The Commands catalog contains all halves, thirds, fourths,
and the Caffeinate toggle. Caffeinate can also be toggled by right-clicking the
Quick Launch menu-bar icon.

Select text in another app before opening Quick Launch, then press `Command-K`
to choose an action. The default Clean Up and Translate actions show the result
first; `Command+K` › Replace Selection then writes it back over the
selection. Summarize opens the result for follow-up. `Control+Option+S` runs
Summarize directly. macOS asks for Accessibility access the first time a
selected-text action needs it.

### Selected text and saved actions

- **Automatic selection.** Select text in another app, then open Quick Launch.
  The selection is captured once, before the panel takes focus, and appears as
  a removable chip under the input row. Press `×` to drop it. The chip goes
  with the next question only. That question keeps the text in front of it:
  it is saved with the chat and goes to the model again, as part of the chat,
  with each follow-up. A new chat starts without it. Reading uses macOS
  Accessibility on the current selection alone: no screen recording, no
  clipboard, never the whole screen. A compact transform
  control beside the chip offers the built-in rewrites — **Make Shorter**,
  **Turn into Bullets**, **Improve Writing**, **Summarize** — plus **Translate**,
  which opens the Translator window with its own target picker. It's fully
  keyboard-first: `⌘⌥T` opens the Transform chooser, `↑`/`↓` move, `↩` runs,
  `esc` closes — or run any transform by its alias (`/shorter`, `/bullets`,
  `/improve`, `/tldr`) or by the `/translate` command.
- **Run a saved action three ways.** By name from `Command+K` (the Quick AI
  action chooser, which searches each action's name and alias), by slash alias
  (`/improve`, `/grammar`, `/tldr`, `/translate`), or by a global hotkey
  (Summarize is `⌃⌥S`). Aliases are fuzzy, so `/eml` finds `/email`.
- **Prompt, output, and context.** A saved action's `prompt` takes
  `{selection}` where the text lands (otherwise it is appended). Rewrite actions
  always **preview first**: the result stays on screen, then you explicitly pick
  **Replace Selection** (writes back to the original captured selection,
  verified against the current one) or **Copy**, or paste into the previous app.
  They never auto-write. Other prompts honour their own output behavior —
  **Show in Quick Launch** or **Replace selected text** — and a custom action
  you define keeps whatever it is set to. Use the explicit focused-context
  commands — `⌘⇧S` Send Focused Window, Send Screen Area, Send Selected Text —
  when you want the window/app context attached beyond a bare selection; the
  attachment card lists exactly what is included. The rewrite prompts are
  adapted from [ray.so's prompt catalog](https://github.com/raycast/ray-so/blob/main/app/(navigation)/prompts/prompts.ts).
- **Configure a custom action.** **Settings › AI Commands** sets its name, fuzzy
  alias, prompt, output behavior, optional global hotkey, and optional
  provider/model.

Raycast parity reference: AI Commands (saved templates) are selected by
name/alias from the root search or a global hotkey, `{selection}` is read via
Accessibility without touching the clipboard, and the output is shown in Quick
Launch or replaces the selection. Sources:
`manual.raycast.com/ai/ai-commands`, `/ai/quick-ai`, `/ai/screen-awareness`,
`/command-aliases-and-hotkeys`.

Slash aliases are fuzzy. `/eml` finds `/email`. Press `Tab` to complete the
alias or `Return` to run the best match. With no alias match, `Tab` opens
Quick AI and sends the typed text at once, so `hi` then `Tab` asks the model
instead of opening the first app.

Pure math such as `sqrt(2)^2` bypasses every model and runs locally. In root search the answer is the top row as you type, and `Tab` or the Ask AI row shows it under its question there; Quick AI does not open. Asked from the Quick AI composer, it stays in the chat: its own answer under its own question, with "Local answer" in the header, never a turn of the chat and never sent to the model. Common date, time, day, and time-zone questions also use trusted macOS data instead of a model.

## Configure models

Open **Settings › Models**.

- Select a built-in provider and refresh its model list.
- Open **Manage models** for one list of every model from every provider, each with its Speed, Intelligence, and Context window. Switch off the ones you never use and they stop appearing in pickers. **Group by Provider** collapses the list by provider, and the sort menu orders it by Brand, Alphabetically, Speed, Intelligence, or Context Window.
- Set a reasoning effort where the model takes one. The model's own default is marked as such, the choice follows you between models that support it, and it resets on a model that does not. DeepSeek receives its thinking setting; OpenAI-compatible endpoints and the local daemon receive the plain effort field.
- Add an endpoint for LM Studio alternatives, MLX servers, Ollama-compatible
  gateways, or any other server that implements OpenAI Chat Completions.
- Enter its base URL, model ID, and optional API key.
- Edit the global quick-action instruction.

API keys go to a non-synchronizing Keychain item. Provider settings, model
choices, and actions use local `UserDefaults`. Chat history is its own
owner-only file (see "Privacy boundary").

For a saved action, open **Settings › AI Commands**. Set its name, fuzzy alias,
prompt, output behavior, optional global hotkey, and optional provider and
model. An unpinned action uses the current model. Use `{selection}`
inside the prompt to control where selected or typed text is inserted.

The **Assistant** card under it turns the action into an assistant. Fill in
**Instructions** (an action with a command cannot be one, so the field is off).
Once it is an assistant, choose **Tools** (Chat defaults, or pick Memory,
Vault, Skills, and Web search one by one), and add **Context skills** from the
folders in `~/.claude/skills`. A skill that is
no longer there is marked and skipped. The skills are read once per chat and
go into the system message after the instructions, ahead of the app's own
instruction.

`Command+,`, the menu-bar Settings item, and Settings in the launcher's ⋯ menu
all open the same settings interface. The main launcher shortcut is editable in
**Settings › General**. A shortcut
already owned by macOS, such as the default Spotlight `Command+Space`, shows a
conflict message instead of failing silently.

Open **Settings › Items** to give any installed app a search alias and optional
global hotkey. You can also highlight an app in the launcher and press
`Command+K` to open its action pane, then edit the same alias and hotkey there.
Finder is included as an app through `/System/Library/CoreServices`.

Open **Settings › Clipboard & Capture** to reload the Tuna Snippets and
Quicklinks and to configure or clear Clipboard History. Their aliases and global
hotkeys are in **Settings › Items**.

## Web search and Pi skills

The `/search` action and time-sensitive questions use the existing SearXNG
service over its warm SSH connection. Quick search sends only five ranked
titles, links, and short snippets to the selected model. It does not fetch full
pages. The source bundle is bounded and marked as untrusted external data.

The Pi provider still runs a fresh one-shot `pi` process for prompts that need
Pi extensions, skills, prompt templates, or custom tools. It disables Pi's
built-in raw file tools for these one-shot runs.

Pi can use the tools and skills in its own configuration. OpenAI-compatible
providers get Quick Launch's own tool loop, below.

## Tools inside the chat

An OpenAI-compatible model can call read-only tools that Quick Launch runs
itself, each through a CLI with an argv array (no shell) and a timeout:

| Tool | Runs | Limit |
|---|---|---|
| `recall_memory(query)` | `recall search <query> --json` over `~/memory` | 5 s |
| `recall_today()` | `recall today --json` | 5 s |
| `search_vault(query, mode)` | the Vault Search SSH lane; `mode` is current, reconcile, history, or portfolio | one try, 8 s |
| `read_skill(name)` | `~/.claude/skills/<name>/SKILL.md`, `name` checked against the folder listing | 12,000 characters |
| `search_web(query)` | SearXNG, as before | 8 s |

The descriptions tell the model to use memory and the vault only when you ask
about your own notes, projects, clients, decisions, or files, and a skill when
you name one or ask how you do something. An answer may use six tool rounds and
30 seconds of tool time; after that the model is asked to answer with what it
has. Every call leaves a line in the thread, saved with the answer. Memory and
vault hits list their sources under the answer (`~/memory` files as they are;
vault paths mapped from `/home/ubuntu/vault-private/` to `~/vault/`), and Open
Source (`⌘O`) opens one with `/usr/bin/open` when it is a document (text,
Markdown, PDF, image, Office, or email) inside `~/memory` or `~/vault`. `⌘K` ›
Tools (`⌥⌘K`) sets the chat's tools; a chat you start with `⌘N` begins on the
chat defaults in Settings › General › Chat (Memory, Vault, Skills, and Web
search, all on out of the box), and a chat the next question starts on its own
keeps the open chat's choice. Long chats are
held to a budget from the model's context window: older tool results go first,
then old turns, and the results the model just fetched last, never the first or
the current question. Capture to Memory (`⌥⌘M`) is the one write, and only you
can run it: it sends the answer on screen to `recall remember`. No tool runs a
skill, sends mail, or changes a file.

Continue in pi (`⌥⌘P`, or `⌘K` › Continue in pi in Quick AI or AI Chat) moves a
chat into a full pi session instead: the thread is written as Markdown to
`~/Library/Application Support/Quick Launch/pi-handoff/`, a detached tmux
session `ql-<id>` starts in your home folder running `pi @<file>` with a short
instruction, and a new Ghostty window attaches to it (`open -n -b
com.mitchellh.ghostty --args -e tmux attach-session -t ql-<id>`, the way
Ghostty's own help names for macOS). Needs `tmux` and `pi` in `~/.local/bin`,
`/opt/homebrew/bin`, `/usr/local/bin`, or `PATH`. If Ghostty does not open, the
session still runs and `tmux attach -t ql-<id>` is copied. Quick Launch does
not stop the session; close it in tmux as usual.

## Attachments

Quick AI and AI Chat take files, links, pictures, and selected text as
context for a question. The model reads them; nothing is changed.

**How to attach.** Add Context (the plus circle, or `@` in the composer)
lists the four captures, then File…, Link…, and Finder Selection (only when
Finder is the app behind the overlay). You can also paste files, an image, or a
lone web link into the composer (`⌘Z` turns a pasted link back into text), or
drop them on Quick AI or on the AI Chat thread and composer. A web address in
your question is read once and kept with that question.

**What you can attach.** PDF; Word (docx, doc, rtf, odt); PowerPoint (pptx);
Excel (xlsx); HTML; plain text, Markdown, and code; web pages; and images
(PNG, JPEG, HEIC, TIFF, GIF, WebP). Pages, Numbers, Keynote, archives, audio,
video, and folders are refused with a line that says why. A scanned PDF is read
with on-device OCR (the first 10 pages without text).

**Limits.** 10 attachments and 6 images a question. 50 MB a document, 20 MB an
image, 5 MB a text file. 200,000 characters of text a file (100,000 for a web
page) and 400,000 a question; a cut is said on the chip and to the model. A
link is one fetch: http or https, 15 seconds, 5 MB.

**How it reaches the model.** Each attachment goes in front of its question as
one block the model is told is data, never instructions. Later questions in the
same chat send it again, so you never re-attach for a follow-up. Pictures go to
the vision model with their own question; with no vision model available, they
are read as text on this Mac instead. Long attachments are cut to fit the
model's window (older ones first), and the thread names what was cut or left
out.

**What is stored.** Chat history keeps a reference to each attachment (its
name, kind, size, a content hash, and the file path or link), never its text
and never a picture. The text is held in memory while the app runs, bounded,
oldest out first; Clear History empties it. After a relaunch an old
attachment's chip reads "Not loaded" with Re-attach: the file is read again,
or the link fetched again, only when you choose it, and a file that changed
since is not used in its place. Pictures read "Image not kept". Continue in pi
writes each attachment's line and its text into the hand-off file; pictures
are named, never written. No attachment is written to the Clipboard History.

## Privacy boundary

- Math and LM Studio stay local.
- Screenshots go to the Vision model in Settings › Models: DeepSeek
  `deepseek-flash`, a cloud API, by default, or the local MLX server at
  `127.0.0.1:8078` when you choose it. They stay in memory for the thread and are
  never written to history or settings.
- There is no Apple on-device provider; it was removed on 2026-08-22 (see "Removed").
- API and CLI subscription providers receive everything a question sends: the
  question, every earlier question and answer of the chat, the app's
  instruction, a saved command's or an assistant's instructions and context
  skills, any Add Context or selected text that went with this or an earlier
  question, the text of files and links attached to the chat (while this
  session holds it; see "Attachments"), web search snippets, and the text of a
  page whose address you typed. An OpenAI-compatible provider also receives
  what the chat's tools return; the Claude Code CLI provider runs with no
  tools.
- The memory and skill tools read local files only. The vault tool sends its
  query over SSH to vault-vps, as Vault Search does. What a tool returns goes to
  the chat's model while it writes that answer, so a cloud model sees the lines
  it found; the answer then stays in the chat. Turn a tool off for one chat in
  `⌘K` › Tools, or for new chats in Settings › General › Chat.
- Chat history is local, optional, and owner-only
  (`~/Library/Application Support/Quick Launch/chat-history.json`, `0600`). Each
  question is saved with any Add Context or selected text in front of it; web
  search snippets and page text are not saved. An attachment is saved as a
  reference only (name, kind, size, hash, path or URL), never its text. A new install keeps 100 chats
  (20, 50, 100, or 200 in Settings › General › History); pinned chats are never
  pruned.
- Continue in pi writes the thread's text (never its screenshots) to
  `~/Library/Application Support/Quick Launch/pi-handoff/`, owner-only (folder
  `0700`, files `0600`), keeping the 20 newest files. pi then sends it to pi's
  configured model, like any pi session.
- The clipboard history is local, optional, deduplicated, and bounded. It keeps
  the full copy (text, an image, rich text, or a file URL) so a later paste
  restores the original representation. It honours concealed/transient
  pasteboard markers, stays owner-only, and is stored in
  `~/Library/Application Support/Quick Launch/clipboard-history.json` (metadata)
  and the adjacent `ClipboardBlobs/` directory (original copy data). Copies over
  20 MB total, images over 12 MB, rich text over 5 MB, or text over 200 KB are
  skipped. History payloads are capped at 200 MB, including pins. Text
  recognized from copied images (on-device Apple Vision) is indexed so the
  clipboard catalog matches words inside images; recognition never changes the
  stored image.
- Picked colours are local and bounded, stored as numbers (no pixels, no
  screenshots) in `~/Library/Application Support/Quick Launch/color-history.json`.
  The eyedropper uses AppKit's own colour sampler, so it needs no screen
  recording permission and captures no image.
- Text read from a screen area is recognised on this Mac with Vision and goes to
  the clipboard. The captured pixels are not saved.
- Tuna snippet and Quick Link values are read at runtime and are not logged or
  copied into Quick Launch settings.
- Selected-text actions use macOS Accessibility only to read or replace the
  current selection. They do not record the screen.
- The interaction journal is local and bounded: outcome rows only (identifiers,
  category codes, a coarse query-size band, and a keyed digest of the folded
  query), kept in `~/Library/Application Support/Quick Launch/interaction-journal.json`
  with `0600` permissions. The digest is HMAC-SHA256 under a random 32-byte key
  generated on first use and stored owner-only beside it
  (`interaction-journal-key`, re-checked to `0600` on every load); repeats
  correlate on this Mac and the digest cannot be recomputed without that file.
  It never stores clipboard, snippet, chat, selection, file, query, or AI answer
  text: the input field — which also carries AI prompts, and whose Ask AI row is
  digested like any other accepted row — is reduced to that digest before it is
  written, with only a coarse size band for its length. An identifier that could
  carry content is digested the same way. That includes the typed-URL row: the
  launcher identifies it by a stable FNV-1a content hash, which is irreversible
  in practice but is *not* cryptographic (it has no key, and ranking cannot use
  one), so the journal re-keys that row id under its own HMAC key before writing
  it. This is not a secret store: a short query remains guessable by brute force
  from the digest plus the key file, so nothing that must stay secret belongs in
  the search field. The "wrong choice" marker is set only by an explicit,
  reversible action, and nothing in the journal feeds ranking.
- Turning the journal off stops new recording. Events already kept stay on this
  Mac, remain exportable and clearable, and still age out on the same retention.
- The app has no analytics and sends nothing about your use anywhere. It keeps
  one bounded local review log, the interaction journal above; exports happen
  only to a location you pick in a save panel.

## Architecture

```text
OverlayView (launcher panel)
  → QuickViewModel
      → QuickStore: settings and chat history, shared with AI Chat
      → cached local application catalogue, including Finder
      → live Tuna snippet and Quick Link catalogues
      → bounded local clipboard history
      → bounded SearXNG snippet bundle
      → OpenAI-compatible SSE service
      → one-shot CLI service (Claude Code or Pi)

AIChatWindowView (AI Chat window)
  → AIChatWindowModel: chat list rail, find in chat, Keep on Top, keys
      → QuickViewModel (the window's own composer, thread, and stream)
          → the same QuickStore and services as the launcher

QuickSettings
  → provider and model catalogue
  → shared launcher-item aliases and hotkeys
  → saved action routes, aliases, output behavior, and hotkeys
  → bounded follow-up settings

SelectedTextService
  → focused selection through macOS Accessibility
  → direct replacement with a paste fallback

Keychain
  → provider API keys
```

The implementation uses SwiftUI, AppKit, `URLSession`, `Process`, and the macOS
Security framework. CLI prompts are sent over standard input. They are never
interpolated into a shell command.

## Performance contract

- The app catalogue is read once at launch. Typing never scans the file system.
- The panel resizes from state changes. Clipboard History uses one lightweight
  pasteboard change-count check per second when enabled. No other idle poll runs.
- Provider startup, model discovery, update checks, and web requests run only
  after an explicit action.
- App discovery and 100 fuzzy filters each have a 250 ms regression gate.
- Quick web search uses snippets rather than full-page extraction and has an
  eight-second retrieval ceiling.
- A silent web-answer model (no text and no tool line yet) is stopped after 15
  seconds. Linked results appear instead of an endless spinner.
- An answer's tool loop has six rounds and 30 seconds of tool time; a stuck
  tool is cut at the budget and the model answers with what it has.

## Deliberately not in the core build

Finder file actions, document attachments, screenshot library management, the
full Tuna translation window, voice input, and a larger chat workspace are
deferred. AI Chat is the one chat window: one conversation over the same
providers and tools, with no autonomy, projects, automations, or file changes. Explicit clipboard image attachments are supported. Quick Launch does
not watch the screen on its own: the only continuous capture is the opt-in owned
Screen History capture, off by default, switched on with "Enable owned screen
capture" in its own Settings tab, stored only on this Mac, and hard-locked in
the current build until the privacy review and soak test pass.

## Agent Watch hooks

Quick Launch keeps the Mac awake while an agent turn is running by watching
small JSON files that agent hooks write. Point the hooks at the bundled
script (it never fails a turn):

```bash
cp scripts/quick-launch-agent-event ~/.local/bin/ && chmod +x ~/.local/bin/quick-launch-agent-event
```

Claude Code (`~/.claude/settings.json`): `UserPromptSubmit` → `quick-launch-agent-event start claude`,
`Stop` and `SessionEnd` → `quick-launch-agent-event stop claude`. Codex (`~/.codex/hooks.json`):
the same three with `codex`. Hooks that still point at the Tuna Companion CLI
keep working; Quick Launch watches that folder too.

## Removed

- **Apple on-device AI via `apfel` (2026-08-22).** The upstream fork shipped an
  `apfel --serve` helper process that exposed Apple's Foundation Model over
  localhost, plus MCP server configuration for that route. Apple Intelligence
  is not available to this project, so the helper, the `ApfelServerKit`
  dependency, the managed provider, and the MCP tab are gone. Settings saved
  by earlier builds load unchanged; a stale Apple selection falls back to
  DeepSeek. The OpenAI-compatible client lives on as `OpenAICompatibleService`.

## License

MIT. See [LICENSE](LICENSE).
