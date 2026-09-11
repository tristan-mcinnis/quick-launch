# Quick Launch primitives

How the whole app fits together, from first principles. Every feature is
built from the five primitives below and must obey the key contract. If a
new feature cannot be described with these words, it does not belong yet.

## 1. Layers

```
Root  ──►  Catalog  ──►  Item  ──►  Action
  │            │           │
  └── Mode ◄───┘           └── Answer (AI thread)
```

- **Root.** The empty launcher. Shows learned favourites first, then Ask AI,
  then the catalogs. Typing searches everything reachable in one ranked
  list: apps, folders, commands, snippets, quick links, catalog names, and
  the Ask AI row. Learned picks outrank text matches; an exact name still
  wins over a related abbreviation. Ask AI's place follows the shape of the
  text: one word keeps it last (a pin or heavy use lifts it above weak
  letters-in-order matches, never above a prefix or exact name); two or
  more words, a question mark, or a leading verb put it just under a title
  prefix, so it beats every weak match. Local answers (math, conversions,
  dates, a typed address) sit above everything.
- **Catalog.** A named list of items of one kind: Snippets, Quick Links,
  Clipboard History, Emoji & Symbols, Screenshots, Folders, Caffeinate,
  Chats, Vault Search, Screen History, Colors, Commands (windows, screenshots, toggles, System Settings
  panes, clipboard and screen helpers). Return on a catalog row enters it. Inside, typing filters that
  catalog only. Learned favourites of that catalog float to the top.
- **Item.** One row. Every item has a kind, a title, a detail line, a
  value, and optionally an alias, a global hotkey, search keywords, and a
  pin. Pinned items sit at the top of their catalog, above learned
  favourites, and outrank unpinned matches when you type.
- **Action.** What Return and the other keys do to the item. The action
  table is the single source of truth for the ⌘K pane, the footer hints,
  the key-cap badges, and direct shortcuts. One table, four surfaces.
- **Mode.** A state that captures typing for one purpose: Quick Link input,
  Caffeinate Until, Rename Chat, a Vault Search mode, or an attached
  screenshot waiting for a question. Modes show their name on the left of the
  footer and leave on Backspace.
- **Tool window.** A window of its own for a job the launcher panel is too
  small for. Two exist. The Translator (`⇧⌘T`), a two-pane panel with the
  launcher's footer strip: Escape closes its language list, then clears the
  text, then closes it; `⌘W` closes it at once. AI Chat, a normal resizable
  window for one conversation (`⌘J` from Quick AI, or the "AI Chat" command):
  it has no footer, Escape never closes it, and `⌘W` does. Same tokens and the
  same key meanings, except where the key table says otherwise.
- **Answer.** An AI thread on the Quick AI surface, which replaces the
  launcher list inside the same panel: a header, the thread (each question a
  pill above its answer), and a composer where typing is a follow-up. `⌘J`
  moves the thread to AI Chat.
- **Context.** What travels with the next question: one or more screenshots
  and/or a capture bundle (app name, window title, selected text, focused field,
  readable text, page URL). Shown as one attachment card. The screenshots stay
  in memory for the thread and ride its follow-ups; they are never stored. The
  text goes in front of the question, so it is saved with the chat and sent
  again with the chat's later questions.

## 2. The key contract

The same key means the same thing on every layer.

| Key | Meaning |
|---|---|
| `↩` | Primary action: open, paste, run, browse, ask; on an answer with nothing typed, paste the answer back (or copy, per Settings; AI Chat always copies); with text typed, follow up; while an answer streams, queue the follow-up |
| `⌘↩` | Secondary action: copy, show in Finder, copy link, paste back an answer |
| `⌘⇧↩` | Copy and paste |
| `⌘K` | Open or close the action list for the highlighted row |
| `⎋` | Step back one layer, outermost first: a ⌘K form, the ⌘K pane or palette, a chooser, Recent Chats (its search text first), a stream (what arrived stays as the answer), typed text, an attachment, the Quick AI surface (back to root search, the thread kept), a local answer, a mode, a catalog. At root search it closes the launcher. In AI Chat it closes the ⌘K palette or a chooser, stops a stream, then closes the rename field, the chat list's actions, its search, the list, and the find bar; it never clears typed text or closes the window. In the Translator: the language list, then the text, then the window |
| `⌫` on empty | Pop one layer: a chooser closes, catalog → root, mode → root, answer → root, attachment → removed; it never closes the launcher |
| `⇧↩` | Translate the typed text (direction from the script); in the AI Chat composer, a new line; in its find bar, the previous match |
| `⇥` | Complete a `/alias`; otherwise open Quick AI and send the typed text (a local answer stays in root search instead) |
| `⌘⇧Q` / `⌘⌥Q` / `⌘⌥H` / `⌘⇧R` | Quit / force quit / hide / relaunch a running app |
| `⌘⇧U` | Copy a link without its tracking parameters |
| `⌘N` / `⌘R` | New chat / ask the last question again (after a finished answer, a stop, or an error) |
| `⌘[` / `⌘]` | Previous / next recent chat |
| `⌘P` | Recent Chats inside Quick AI, from root search too; the chat list in AI Chat; nothing in the Translator |
| `⌘H` | Recent Chats on the Quick AI surface (the v1.4 key); in AI Chat it is Hide Quick Launch |
| `⌘J` | Open in AI Chat: the Quick AI chat (in Recent Chats and the Chats catalog, the highlighted chat) moves to the AI Chat window, and the launcher closes |
| `⌃⌘S` | Show or hide the AI Chat chat list |
| `⌘F` | Find in the AI Chat thread; `↩` or `⌘G` next, `⇧↩` or `⇧⌘G` previous |
| `⌘1…9` | AI Chat: open the chat list's first nine chats, shown or not |
| `⌘O` | Open the answer's source (memory and vault hits), or list them when there are several |
| `⌥⌘K` | The chat's Tools in the ⌘K palette: Memory, Vault, Skills, Web search |
| `⌥⌘M` | Capture to Memory: send the answer on screen to `recall remember` |
| `⌥⌘A` | Change Assistant, or back to a plain chat |
| `⇧⌘O` / `⇧⌘R` | Change the model / ask the last question again on another model |
| `⌘W` | Close the AI Chat window or the Translator |
| `⌘T` | Translator: open or close the target-language list |
| `⌥⌘T` | With a selected-text chip: open or close the Transform chooser (Make Shorter, Turn into Bullets, Improve Writing, Summarize, Translate) |
| `⇧⌘M` | Fold or unfold the newest long question in the thread |
| `⌘L` / `⇧⌘W` | Read the answer aloud / search the web for it |
| `↑` on an empty Quick AI composer | Put the last question back in the composer; `↓` does nothing there |
| `PageUp` `PageDown` / `⌥↑` `⌥↓` / `⌘↑` `⌘↓` | Scroll the Quick AI thread by a page / by a page / to the top or bottom |
| `⌘⇧S` / `⌘⇧D` | Send the focused window / this screen to AI (screenshot plus context) |
| double tap right `⌘` | Send the focused window to AI from anywhere |
| `⌘E` | Edit |
| `⌘⇧A` / `⌘⇧H` | Set alias / set hotkey |
| `⌃X` | Delete (press twice) |
| `⌘⇧P` | Pin to the top of its catalog, or unpin (snippets, quick links, clipboard, screenshots, chats) |
| `⌘⇧N` / `⌘⇧L` | Save as snippet / save as quick link |
| `⌘⇧C` | Copy path (apps) or copy answer (Quick AI stays open) |
| `⌥⌘C` | Copy the whole chat, in Quick AI or AI Chat, labelled "You:" and the model |
| `⌥⌘P` | Continue the chat in pi, from Quick AI or AI Chat: a new tmux session, opened in Ghostty |
| `↑ ↓` | Move the highlight |

The launcher list never uses `⌘1…9` to jump to rows. A number key is a row
action where a catalog needs one (a colour's other notations are `⌘1…⌘4`,
Screen History's import review is `⌘1` and `⌘2`), switches Settings tabs (`⌘1…⌘7`),
or, in AI Chat only, opens a chat from the list. The answer keys live in one
table, `ResultAction.shortcut` (`Sources/Models/ItemAction.swift`); the AI Chat
window's own keys in `AIChatWindowModel`, the Translator's in `TranslatorKey`.

Within the Keep my place interval (Settings › General › History, 10 seconds by
default) the launcher reopens where it was left; after it, reopening starts at
the root. Opening Settings or AI Chat from the launcher hides the launcher.

## 3. Surfaces

- **Row.** Icon, title, detail, and a key-cap badge when the item has a
  global hotkey. Selection is an inset rounded fill. Never a button.
- **Footer.** Root search, the catalogs, and the Translator. Left: where
  you are (the model name, catalog name, mode name, "Local answer"). Right:
  the keys that work right now, from the action table. Quick AI and AI Chat have no footer: the
  composer's right edge names what Return does ("Ask", "Paste Response",
  "Stop"), and a list or chooser over the composer (Recent Chats, the model
  and assistant choosers, Add Context, Transform) names its own keys in its
  header line. AI Chat's find bar names its own keys too.
- **⌘K pane.** Header (item), action rows with key caps, search field at the
  bottom. Edit, alias, and hotkey are small forms inside the pane.
- **Grid.** Catalogs of glyphs (Emoji & Symbols) render as a 9-column grid
  with section headers (Frequently Used, All). Arrows move the highlight;
  the same actions apply.
- **Detail pane.** Catalogs of things worth previewing (Screenshots,
  Clipboard History, Screen History) show the list on the left and a preview plus an
  Information block on the right; the panel widens to fit.
- **Answer.** Model answers live on the Quick AI surface: the thread
  scrolls, follows the newest text only while you are at the bottom, and
  shows a "Latest" chip when you are not. A stopped answer stays as the
  turn's answer; a provider error stays under its question with Retry.
  Command output and Vault Search use the same surface with their source
  named in the header, and never join a chat. A local answer (math, a
  conversion, a date) asked in root search shows under the input row and
  never opens the surface; asked in a chat, it stays there under its own
  pill ("Local answer" in the header), never a turn. Copy and paste are
  keys, not buttons. Recent chats are a
  catalog (Chats) and a list in Quick AI (`⌘P`), with one search, one order,
  and one set of row actions: Continue Chat, Open in AI Chat (`⌘J`), Copy
  Last Answer, Rename, Pin, Delete, on the highlighted row. `⌘J` moves the
  chat to the AI Chat window, one conversation window with the same thread
  and composer, a multi-line composer, find (`⌘F`), and a chat list hidden
  until `⌃⌘S` (Pin, Rename, and Delete on its rows).
- **Settings.** A sidebar of seven tabs (`⌘1…⌘7`), no system tab view. The
  Items tab is one searchable table of every configurable item with its alias
  and hotkey in place.

## 4. Speed contract

- Hotkey to visible panel: no animation, no Accessibility read, no file I/O.
- One ranking pass per keystroke, cached and shared by the list, the footer,
  and the panel sizer. 1.3 to 1.9 ms for 250 apps plus catalogs.
- Streamed tokens are published at most every 33 ms; the answer is parsed
  and laid out only when its text changed.
- The clipboard image is decoded once per pasteboard change. App icons are
  cached and warmed after launch. Clipboard History writes off the main thread.
- Catalog data is read once at launch (apps) or lazily on first open
  (emoji). Nothing polls except the 1-second clipboard change-count check.
- No helper processes, no HTTP server, one package dependency.

## 5. Learning

The typed text and the chosen item are remembered per catalog with a
14-day half-life. Three tiers: exact abbreviation, related abbreviation,
plain use count. Global hotkey runs count as uses. Local JSON, bounded,
one toggle, one Forget button.

## 6. Privacy boundaries

- Screenshots live in memory for one thread and ride its follow-ups; never in
  history or on disk. The text of a capture bundle or a selected-text chip is
  part of the question it went with, so it is saved in chat history
  (owner-only) and goes to the provider again with the chat's later questions.
- Attachment text is held in memory for the session only; chat history keeps a
  reference (name, kind, size, hash, path or URL), never the text. The text of
  a chat's attached files and links goes to the provider again with the chat's
  later questions, as long as the session holds it; after a relaunch a file is
  read again, or a link fetched again, only when the user chooses Re-attach.
  Attached images stay in memory for the session and are never written.
- Screen History frames and OCR remain in owner-only local stores. The search-only beta hard-locks capture. The latent capture path requires FileVault and visible consent after each launch, and all browsers are refused before pixels are read. The editable application and domain exclusions govern capture, search, and migration. A result proves only that something was visible at that time. It never reports current project truth.
- The screenshot text index is on-device OCR (Vision), one local JSON file,
  switchable off in Settings › General.
- Snippet and clipboard values never reach logs or diagnostics.
- A cloud provider receives the whole chat, not only the current question:
  every earlier question and answer, the app's instruction, a saved command's
  or assistant's instructions and context skills, the capture or selection
  text, the text of attached files and links, web search snippets and
  typed-page text, and, for an OpenAI-compatible
  provider, what the chat tools return (memory hits from `recall`, vault
  results over SSH, a skill's `SKILL.md`, web results). The Claude Code CLI
  provider runs with no tools. Screenshots go to the Vision model setting,
  DeepSeek by default. Tools are switchable per chat (`⌘K` › Tools) and for new chats
  (Settings › General › Chat).
- Clipboard history keeps text, images, rich text, and file URLs; it is local,
  bounded, pinnable, and clearable, and it skips copies of AI answers (marked
  transient).

## 7. Adding a feature: the checklist

1. Is it a catalog, an item, an action, a mode, or an answer?
2. Which existing keys apply? Add to the action table, not to a view.
3. What does the footer say in this state?
4. What does Backspace pop to?
5. Does it need a global hotkey or alias? Then it is an item and appears in
   the Settings table automatically.
6. Write the test against the view model, then the render proof.
