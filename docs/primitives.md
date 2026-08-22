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

- **Root.** The empty launcher. Shows learned favourites first, then the
  catalogs. Typing searches everything reachable in one ranked list: apps,
  commands, snippets, quick links, catalog names. Learned picks outrank text
  matches; an exact name still wins over a related abbreviation.
- **Catalog.** A named list of items of one kind: Snippets, Quick Links,
  Clipboard History, Emoji & Symbols, Screenshots, Windows, Caffeinate,
  Commands. Return on a catalog row enters it. Inside, typing filters that
  catalog only. Learned favourites of that catalog float to the top.
- **Item.** One row. Every item has a kind, a title, a detail line, a
  value, and optionally an alias, a global hotkey, search keywords, and a
  pin. Pinned items sit at the top of their catalog, above learned
  favourites, and outrank unpinned matches when you type.
- **Action.** What Return and the other keys do to the item. The action
  table is the single source of truth for the ⌘K pane, the footer hints,
  the key-cap badges, and direct shortcuts. One table, four surfaces.
- **Mode.** A state that captures typing for one purpose: Quick Link input,
  Caffeinate Until, Rename Chat, or an attached screenshot waiting for a
  question. Modes show their name on the left of the footer and leave on
  Backspace.
- **Tool window.** A second panel for a two-pane job: the Translator
  (`⇧⌘T`). Same tokens, same footer, same key meanings; Escape closes it.
- **Answer.** An AI thread. While an answer is on screen the launcher list
  is hidden; typing is a follow-up; the question is shown above the answer.
- **Context.** What travels with the next question: one or more screenshots
  and/or a capture bundle (app name, window title, selected text, focused field,
  readable text, page URL). Shown as one attachment card; sent once, as an
  image plus a bounded text preamble; never stored.

## 2. The key contract

The same key means the same thing on every layer.

| Key | Meaning |
|---|---|
| `↩` | Primary action: open, paste, run, browse, ask; on an answer with nothing typed, paste the answer back; with text typed, follow up |
| `⌘↩` | Secondary action: copy, show in Finder, copy link, paste back an answer |
| `⌘⇧↩` | Copy and paste |
| `⌘K` | Open or close the action list for the highlighted row |
| `⎋` | Close the overlay from anywhere (a ⌘K form steps back first; a stream stops first) |
| `⌫` on empty | Pop one layer: catalog → root, mode → root, answer → root, attachment → removed |
| `⇧↩` | Translate the typed text (direction from the script) |
| `⌘N` / `⌘R` | New chat / regenerate the last answer |
| `⌘[` / `⌘]` or `↑ ↓` on an answer | Previous / next recent chat |
| `⌘⇧S` / `⌘⇧D` | Send the focused window / this screen to AI (screenshot plus context) |
| double tap right `⌘` | Send the focused window to AI from anywhere |
| `⌘E` | Edit |
| `⌘⇧A` / `⌘⇧H` | Set alias / set hotkey |
| `⌃X` | Delete (press twice) |
| `⌘⇧P` | Pin to the top of its catalog, or unpin (snippets, quick links, clipboard, screenshots, chats) |
| `⌘⇧N` / `⌘⇧L` | Save as snippet / save as quick link |
| `⌘⇧C` | Copy path (apps) or copy answer |
| `↑ ↓` | Move the highlight; `⌘1…9` is deliberately unused |

Reopening the overlay always starts at the root. Opening Settings hides the
overlay.

## 3. Surfaces

- **Row.** Icon, title, detail, and a key-cap badge when the item has a
  global hotkey. Selection is an inset rounded fill. Never a button.
- **Footer.** Left: where you are (model name, catalog name, mode name).
  Right: the keys that work right now, from the action table. The footer
  is the only place that explains keys; no hint text inside lists.
- **⌘K pane.** Header (item), action rows with key caps, search field at the
  bottom. Edit, alias, and hotkey are small forms inside the pane.
- **Grid.** Catalogs of glyphs (Emoji & Symbols) render as a 9-column grid
  with section headers (Frequently Used, All). Arrows move the highlight;
  the same actions apply.
- **Detail pane.** Catalogs of things worth previewing (Screenshots,
  Clipboard History) show the list on the left and a preview plus an
  Information block on the right; the panel widens to fit.
- **Answer.** Earlier turns compact and scrollable above, the latest question
  and answer in full, footer hints. Copy and paste are keys, not buttons.
  Recent chats are a catalog (Quick AI Chats): continue, copy last answer,
  rename, pin, delete.
- **Settings.** A top tab strip, no system tab view. One searchable table
  lists every configurable item with its alias and hotkey in place.

## 4. Speed contract

- Hotkey to visible panel: no animation, no Accessibility read, no file I/O.
- One ranking pass per keystroke, cached and shared by the list, the footer,
  and the panel sizer. 1.5 to 2.7 ms for 250 apps plus catalogs.
- Catalog data is read once at launch (apps) or lazily on first open
  (emoji). Nothing polls except the 1-second clipboard change-count check.
- No helper processes, no HTTP server, one package dependency.

## 5. Learning

The typed text and the chosen item are remembered per catalog with a
14-day half-life. Three tiers: exact abbreviation, related abbreviation,
plain use count. Global hotkey runs count as uses. Local JSON, bounded,
one toggle, one Forget button.

## 6. Privacy boundaries

- Screenshots and capture bundles live in memory for one thread; never in
  history or on disk.
- The screenshot text index is on-device OCR (Vision), one local JSON file,
  switchable off in Settings › General.
- Snippet and clipboard values never reach logs or diagnostics.
- Cloud providers receive only the text (and image) of the current action.
- Clipboard history is text, local, bounded, pinnable, and clearable.

## 7. Adding a feature: the checklist

1. Is it a catalog, an item, an action, a mode, or an answer?
2. Which existing keys apply? Add to the action table, not to a view.
3. What does the footer say in this state?
4. What does Backspace pop to?
5. Does it need a global hotkey or alias? Then it is an item and appears in
   the Settings table automatically.
6. Write the test against the view model, then the render proof.
