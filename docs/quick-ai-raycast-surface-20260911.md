# Quick AI: the Raycast surface

Build contract, 2026-09-11. Reference: <https://manual.raycast.com/ai/quick-ai>
and its screenshot `mac-ai-quickai.png` (2000 × 1250 px at 2×, window 750 × 475
pt). Every number below was measured from that image and rounded to the nearest
house token. This is personal software; the brief is "as close to Raycast as the
tokens allow", not "inspired by".

## What was wrong (v1.3.0)

1. Tab from root search only switched the launcher into an "Ask AI" input mode.
   The panel kept its launcher shape, the composer stayed at the top, and nothing
   was sent. Raycast hands the typed text to Quick AI and starts answering.
2. The answer drew under the top composer as a stack of `ANSWER` / `YOU` section
   labels, a question chip, and a compact transcript. Raycast is one thread: user
   turns as right-aligned pills, answers as plain prose, composer at the bottom.
3. `⌘J` opened a split view: a chat rail on the left, the thread on the right.
   The user reads this as a "dual panel" and does not want it.
4. The model opened a "What can I help you with?" multiple-choice card on a plain
   factual question, because the `ask_user_question` tool description says
   "prefer this over guessing". Raycast asks only when a request is ambiguous.

## The surface

One fixed window: `House.Layout.panelWidth` (750) × `House.Layout.quickAIHeight`
(475), same glass, radius, stroke, and shadows as the launcher panel. It replaces
the launcher panel in place (same top edge, centred, same 750 width), so the
only motion on Tab is the height changing: it grows from an empty or short root
search and shrinks from a root search with a full page of rows, since the
surface is fixed and never measures its content. A catalog with a detail pane
(960 wide) is the one root state wider than the surface; Tab from it jumps to
750 in the same frame as the height.

```
┌──────────────────────────────────────────────────────────────┐
│  ‹   Raycast Founder                                     ⤢    │  header, 60 high
│      Claude Haiku 4.5                                        │
│                                                              │
│                                          ( raycast founder ) │  user pill, right
│                                                              │
│  🌐 Search web: Raycast founder and 2 more terms             │  tool line, tertiary
│                                                              │
│  Raycast was co-founded by Thomas Paul Mann (CEO) and …      │  answer, prose
│                                                              │
│                                                              │
│                                                              │
│ (+) [ Ask anything, @ tools, or / for commands…  Paste Response ↩ ] (⌘) │  composer row
└──────────────────────────────────────────────────────────────┘
```

### Header (top, 60 pt)

- Left: a `chevron.left` glyph button at `Control.compact` (28) square, inset
  `Spacing.sm` (12) from the left edge; Escape and the button both go back to
  root search (the thread is kept, `⌘N` starts a new one).
- Beside it, two lines: the conversation title in `TypeToken.subheading`
  (13 semibold; Raycast is ~15 semibold and 13 is the nearest house style),
  and the model display name under it in `TypeToken.metadata`
  `textSecondary`. Title falls back to the first user
  message, truncated middle, one line. Before the first answer the title is
  "Quick AI".
- Right: an `arrow.up.right.square` (expand) glyph button, same size, inset
  `Spacing.lg`. Raycast draws a boxed up-right arrow; this is the nearest SF
  Symbol, at `TypeToken.glyphMedium` (16 semibold) in `textPrimary`. The back
  chevron is quieter: `TypeToken.glyphSmall` (14 semibold) in `textSecondary`,
  and the header's left inset is `Spacing.sm` (12) so the title starts at
  52 pt, where Raycast's does.
- No divider under the header. Raycast has none.

### Thread (scrolling, fills between header and composer)

- Horizontal gutter `Spacing.lg` (20) on both sides.
- User turn: a pill on the right. `chipFill`, `Radius.pill`, `TypeToken.body`
  (13) `textSecondary` (Raycast's pill text is a step smaller than the prose
  and grey), padding `Spacing.sm` (12) horizontal, `Spacing.xs` (8) vertical,
  so the pill is about 31 high; max width `quickAIAnswerMaxWidth` (690), text
  wraps left-aligned inside the pill. No "YOU" label.
- Tool / status line: a `globe` (web search) or `sparkles` glyph and one line of
  `TypeToken.body` `textTertiary`. Draw for a running or finished web search
  ("Search web: …"); while the model is thinking with no text yet draw the
  `ThinkingIndicator` and the status text on the same line. No "ANSWER" label.
  Raycast fills its globe blue; the house rule keeps accent for focus rings
  and links, so the glyph stays a `textTertiary` outline. A deliberate
  deviation, not an oversight.
- Assistant turn: `MarkdownTextView` prose, left aligned, max width 690, no
  card, no fill. Line height is the house 1.55 (about 21.7 pt for 14 pt
  text), reached by adding only the difference over SF's own line height
  (`TypeToken.proseLineSpacing`, about 5 pt), never 0.55 × 14 on top of it.
  Code blocks keep the v1.3.0 block (language, Copy, wrap).
- A finished answer that is not a conversation turn (a local answer such as
  `2+2`, a command action's result, a Vault Search, the partial text a failed
  stream left) draws as prose after the thread, whether or not a chat is kept.
- An answer never draws without its question. The typed question is a pill
  from the moment it is submitted: while the web search or page read runs it
  draws as its own pill with the search line under it (the user message joins
  the thread only when the model is called), and a local answer draws under
  its own pill. The previous answer leaves the screen when the next ask
  starts; nothing is drawn live until the model's text lands.
- Ask User Question card, when the model genuinely asks, sits in the thread at
  the assistant position and keeps its current look.
- Long messages keep the Show more / Collapse control.

  > Changed in v1.5.0: only user turns collapse; answers always draw in
  > full, as Raycast does. The threshold is measured at the pill's width
  > (about 105 characters a line, not 60), and Show more and Collapse scroll
  > the message's first line to the top of the thread. Only the newest
  > collapsible turn, the one `⇧⌘M` acts on, shows the key caps, in both
  > Show more and Collapse.
- Vertical rhythm: `Spacing.md` (16) between turns, `Spacing.xl` (24) above the
  first turn.
- The thread auto-scrolls to the newest turn while streaming.

### Composer row (bottom)

- Inset `Spacing.xs` (8) on every side from the panel edge. Row height
  `Control.pill` (36).
- Left: a `plus` glyph in a `Control.pill` (36) circle, `surfaceTint` fill,
  `stroke` hairline. Opens Add Context; `@` in the field does the same.
- Middle: the field. `Control.pill` high, `Radius.pill` (18) corners drawn as
  a circular `RoundedRectangle` (SwiftUI's `Capsule` stroke leaves a stray
  hairline at its left cap), `stroke` hairline and no fill (Raycast's field
  is an outline on the glass; only the plus circle carries a faint fill),
  `TypeToken.bodySmall` (13) text, the same size as Raycast's action label
  (Raycast's field is 13, not 16), placeholder "Ask anything, @ tools, or /
  for commands…" in `textTertiary`, drawn as an overlay on the field's text
  origin since a styled prompt takes the field's ink on macOS (v1.5.0: "Ask a
  follow-up…" once a thread exists, "Search chats…" in Recent Chats, "Waiting
  for the answer… esc stops" while streaming, the web-search phase included,
  since the question leaves the field for its pill when the search starts,
  "Pick an option above… esc stops" while the question card waits). Left text inset
  `Spacing.md` (16). On the right, inside the field: the primary action label in
  `TypeToken.label` `textPrimary` ("Paste Response" or "Copy Response" per the
  Primary Action setting; "Ask" before an answer exists; "Stop" while streaming;
  "Open" in Recent Chats; v1.5.0: the open chooser's own action, "Use Model",
  "Regenerate", "Add", or "Run", while one floats above the composer) followed
  by its key cap (`↩`, or `esc` while streaming).
- Right: a `command` glyph in a `Control.pill` (36) circle, the twin of the
  plus circle across the field (Raycast's ⌘ is a circle, not a rounded
  square: its fill has the chord profile of the plus button), `stroke`
  hairline and no fill, `textPrimary` in both states (Raycast's ⌘ is full
  ink); while the panel is open the circle's fill is `hoverFill`. Opens the
  `⌘K` action panel. The plus, ⌘, and expand glyphs are set in
  `TypeToken.glyphMedium`.
- Gaps between the three: `Spacing.xs` (8).
- There is no footer well and no status dot on this surface. The composer row is
  the footer.

### Focus and keys

- The field has focus the whole time the surface is open, including while a
  question streams (typing a follow-up during streaming queues nothing; Return is
  ignored until the stream ends).
- `↩` sends; with an answer and an empty field it runs the primary action.
- `esc` while streaming stops, the search phase included: a stopped ask never
  reaches the model, and the search line it started leaves with it. Otherwise
  `esc` goes back to root search with the thread kept. A second `esc` in root
  search closes the window as today.
- `⌘R`, `⇧⌘R`, `⌘N`, `⌘[`, `⌘]`, `⌘K`, `⌘L`, `⇧⌘M`, `⇧⌘V` keep their v1.3.0
  meanings.

  > Added in v1.5.0: `⌥⌘P` (and `⌘K` › Continue in pi) hands the thread to
  > a new pi session in tmux and opens Ghostty on it. The thread then ends
  > with one tool line in the same style as the search line, a `terminal`
  > glyph and "Opened in pi · tmux session ql-…", until the next question
  > or another chat.
- `⌘J` opens Recent Chats: the same window, the thread replaced by the
  launcher's own chat rows (the Chats catalog rows: 26 px icon tile, `label`
  title, `meta` question count and time, 40 high), pinned first, then newest
  first. `↑↓` moves, `↩` opens that chat in the thread (the composer reads
  "Open ↩"), `esc` returns to the thread. One column. The split view is
  deleted. `⌘J` enters through the same path as Tab, so a catalog, an input
  mode, or a Quick Link input steps aside and the composer's Return asks.

  > Changed in v1.5.0: the composer searches the list (title and message
  > text) and opens empty; Return opens the highlighted match and clears the
  > text; `esc` clears a search before it returns to the thread.
- While an answer streams, Return still picks in the model chooser, Add
  Context, and the Transform chooser; only the ask itself waits for the
  stream to end.

## Entering Quick AI

- Root search with text + `Tab`: open the surface and submit the text
  immediately. Same for the Ask AI row and the Ask AI fallback command on `↩`.
- Root search with no text + `Tab`: open the surface empty, field focused, title
  "Quick AI".
- The `⇥` hint on the Ask AI row stays, under its setting.
- A saved-prompt alias match on Tab still completes the alias (unchanged).
- Selected text captured at launch and attachments carry over as today and show
  above the composer as the existing strip, inside the surface.

## Ask User Question

- The tool description tells the model to ask only when a request cannot be
  answered without a decision the user must make, and never on a request that
  has one reasonable reading. Add "Do not ask which kind of help is wanted."
- A new Quick AI setting, "Let the model ask clarifying questions", default
  off. When off the tool is not offered at all. Existing behaviour is reachable
  by switching it on.

## Model

> Superseded in v1.4.1: the DeepSeek API serves one flash model, `deepseek-flash`
> (V4.1 Flash, text and images). Both ids below are aliases of it and migrate to it.

- Quick AI's model is chosen in Quick AI settings (default model) and mid-thread
  through `⌘K` › Change Model, as in v1.3.0. Both must show only enabled models.
- Default text model: `deepseek-v4-flash`. A settings migration (bump the
  configuration version) moves a DeepSeek `selectedModel` that still sits on
  `deepseek-v4-flash-vision-exp` to `deepseek-v4-flash`; any other explicit
  choice stays.
- `deepseek-v4-flash-vision-exp` is sunset for text: the migration disables it
  in Manage Models so it leaves every picker. It remains the image route
  (`visionModel`) until DeepSeek ships vision on the flash id; the footer and
  header show the vision name only while an image is attached.
- The header's second line always names the model that will answer the next
  message, by its display name (`ModelProfile.curatedTable` carries one per
  shipped id: "DeepSeek V4 Flash", "DeepSeek V4 Pro", …; an id with no name
  shows as itself). Reloading a chat (`⌘[`, `⌘]`, Recent Chats, the Chats
  catalog) carries the chat's model over only while that model is still
  enabled; a chat written on the sunset vision id keeps the provider's current
  selection, so the migration is not undone.
- "Search web: …" is cleared when another chat is loaded; it belongs to the
  answer it was made for.

## Window sizing

- `currentPanelWidth` returns `panelWidth` for the Quick AI surface and Recent
  Chats; `estimatedWindowHeight` returns `quickAIHeight` for both. No measured
  markdown height on this surface; the thread scrolls.
- Root search keeps its measured height. Its width is now 750 from the token.

## Not built

- Dictation (`⌃M`). local-dictation owns that.
- A separate AI Chat window. `⌘J` is Recent Chats inside this window.
- Web search citations UI beyond the one status line.

## Proof

- Offscreen render proofs, both appearances: empty surface, the search phase
  of an ask through the real submit path (question pill, search line, nothing
  else drawn), an answered thread with a user pill and prose, the `⌘K`
  palette above the composer, a local answer under its own pill, Recent
  Chats.
- Driven check on the installed app: `⌘Space`, type, `Tab`, screenshot; wait,
  screenshot; `⌘J`, screenshot; `esc` ×3. Compare against `mac-ai-quickai.png`.
- `swift test` green, `design-lint --strict` zero hits on touched files.

## Deviations (built 2026-09-11, v1.4.0)

Where the tokens or the existing contract would not take the line above as
written, this is what was built instead.

- **Header height 58, not 60.** No house control is 60 high; the header uses
  `Control.input` (58), the nearest token. The two lines inside it are `label`
  13 semibold over `metadata`.
- **The vision id is switched off by the curated catalogue, not by a one-shot
  write.** `ModelProfile.curatedTable` ships `deepseek-v4-flash-vision-exp`
  with `enabled: false`, and `ModelPreferenceStore` reads that as the default
  when the user has made no choice. Every text picker loses it on upgrade and
  on a fresh install alike, Manage Models can switch it back on, and Reset in
  Manage Models returns to off rather than on. The configuration-version
  migration (23) moves a DeepSeek `selectedModel` (and a Quick AI model
  override) off it to `deepseek-v4-flash`; the vision route is untouched.
- **`⌘N` keeps the surface.** A new chat starts on the empty surface (title
  "Quick AI"), as in Raycast, rather than dropping to root search. Deleting
  the current chat from `⌘K` does the same.
- **Empty Backspace on the surface is Escape.** It returns to root search with
  the thread kept, the same as the chevron and Escape.
- **Escape with typed text clears the text first.** The overlay's one layer
  rule (typed text pops before anything behind it) is kept, so with a
  half-typed follow-up it is Escape, Escape to root search.
- **Return in Recent Chats always opens the highlighted chat**, typed text or
  not; the list has no search. (Superseded in v1.5.0: the composer searches the list, and Return opens the highlighted match.)
- **The finished-search line is per answer.** "Search web: …" is kept on the
  view model for the answer it belongs to and cleared by the next question; it
  is not written into chat history, so a reloaded chat shows no tool line.
- **Recent Chats keeps the header** (title over model, chevron, expand glyph)
  and puts a "Recent Chats" section label with its key hints (`↑↓`, `↩`,
  `esc`) above the rows. The rows are the launcher's `LauncherResultRow`
  fed from `conversationItems`, not a second list: one row look for chats
  everywhere, and the keys index the same ordering the rows draw.
- **The ⌘K palette floats above the composer**, right-aligned to the panel
  inset, rather than under the input row; the model chooser, Add Context, and
  the Transform chooser float the same way at the panel's full inner width.
  (Round 1 drew it top-aligned over the header; the flexible frame is now
  bottom-aligned on the surface, and the proof measures the pane's top edge
  against the header height.)
- **The ⌘ control is a circle and the field is outline only.** The first cut
  read the reference as a 10 pt rounded square on `surfaceTint`; measured
  again, Raycast's ⌘ has the chord profile of the plus circle and neither the
  field nor the ⌘ carries a fill. Only the plus circle keeps `surfaceTint`.
- **`TypeToken.glyph` is 16, not 18.** The launcher's magnifier and Add
  Context glyph were the one raw font size in the view layer; they now take
  `Size.input`, the size of the field text they sit beside, and the lint
  baseline is zero.
- **The driven check on the installed app is still owed.** The offscreen
  render proofs (`quick-ai-{empty,streaming,answered,actions,local-answer,
  recent-chats}-{dark,light}.png`) stand in for it. Rounds 1 and 2 could not
  run it: the Mac session was locked, screen capture returned the lock screen
  or black frames, and in round 2 the driven keystrokes landed in the login
  password field. The driver now checks `CGSessionCopyCurrentDictionary`
  (`CGSSessionScreenIsLocked`) before every keystroke and screenshot and
  aborts on a locked session, so that cannot happen again. Run it from an
  unlocked session and an unsandboxed shell: hotkey, type, `Tab`, wait,
  `⌘J`, `esc` ×3, and compare against `mac-ai-quickai.png`.
- **Tab from a full root search shrinks the window.** The surface is fixed at
  475; a root search with twelve rows is taller (622). "The height growing"
  above describes the empty and short cases; the fixed height wins.
