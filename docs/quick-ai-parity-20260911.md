# Quick AI parity with Raycast

Target: Raycast's **Quick AI** surface, cloned into Quick Launch's overlay.
Source of truth: <https://manual.raycast.com/ai/quick-ai> and the pages it
depends on (search bar, AI chat, settings, keyboard shortcuts, screen
awareness, dictation), read on 2026-09-11.

This document is the build contract for the parity work. Where Raycast's
manual is silent, the row is marked **undocumented** rather than guessed.

**Status: delivered 2026-09-11 in v1.3.0.** Sections 1 and 2 are the
reconnaissance as found, kept as the record of what was missing. Section 3
lists the calls taken locally. Section 4 is the behaviour now shipped. Section
7 is what was deliberately not built.

---

## 1. What Quick Launch already does

Do not rebuild these. Verified in source, 2026-09-11.

| Raycast behaviour | Quick Launch |
|---|---|
| `Tab` from Root Search hands text to Quick AI | `handleTab()` in `QuickViewModel.swift` |
| `Tab` with no text opens Quick AI fresh | `enterAskAIMode()` |
| Quick AI row in Root Search | always-present `Ask AI` row |
| `↵` streams the answer in the same window | `submit()` / `stream()` |
| `↵` pastes into the previously focused app | `pasteOutputToPreviousApp()` |
| Follow-ups in one conversation | `QuickConversation.messages` |
| `⌘R` regenerate, `⌘N` new chat, `⌘[` `⌘]` browse chats | `ResultAction` |
| Action Panel, `⌘K` | `handleCommandK()` |
| Model picker without leaving the overlay | `moreMenu → modelSubmenu` |
| New chat after a period of inactivity | `newConversationAfterMinutes` |
| Chat history, pin, rename, delete | `QuickHistoryStore`, `.chats` catalog |
| Focused window, screen area, selected text, screenshots | `pendingImage` / `pendingContext` |
| Read aloud | `⌘L`, `LocalSpeechService` |

## 2. Gaps

### 2.1 UI elements

1. **Code blocks.** Raycast: detected language, copy button, sideways scroll by
   default, and an **Enable line wrap** toggle in the top right of the block.
   Quick Launch renders code as plain monospaced text that always wraps, with no
   label, no copy button, and no toggle.
2. **Collapsed messages.** Raycast collapses a message over 10 lines and offers
   **Show more** / **Collapse**. Quick Launch clips the transcript at
   `.lineLimit(3)` for user turns with no control.
3. **Add Context.** Raycast puts an **Add Context** menu to the left of the
   composer, and `@` opens the same menu. Quick Launch has no `@` affordance at
   all; attachments are only reachable through shortcuts and the `⌘K` palette.
4. **Ask User Question.** Raycast renders a short multiple-choice question
   inline in the conversation and continues when an option is picked. Absent.
5. **Dictation state.** Raycast: `⌃M` starts, words appear in the composer,
   `⌃M` or `↵` accepts, `Esc` cancels. Quick Launch has speech out, none in.
6. **Manage Models.** Raycast lists every model with Speed, Intelligence, and
   Context window, a checkbox to enable or disable, **Group by Provider**, and a
   sort menu. Absent; models are bare strings today.

### 2.2 Keyboard behaviour

7. `⇧⌘R` regenerate with a different model. Absent (`⌘R` regenerates same model).
8. **Change Model** as a `⌘K` action. Absent; only the `moreMenu` submenu works.
9. `⌃M` dictation. Absent.
10. Tab hint in Root Search. Absent, and no setting hides it.
11. Tab inside `⌘K` panes. The footer advertises "Tab completes aliases" but
    only the root field handles Tab.

### 2.3 Settings

12. **Primary Action** for an answer (paste vs copy). Not a setting today.
13. **Tab Shortcut** hide toggle. Absent.
14. **Start New Chat**: 5, 10, 15, 30 minutes, 1 hour, always, never. Today a
    bare integer count of minutes.
15. Per-surface **default model** for Quick AI. Absent.
16. **Fallback Commands**: ordered list, drag to reorder, minus to remove;
    unmatched Root Search text runs the first one on `↵`. Today unmatched text
    always lands on Ask AI.
17. Model enable/disable, grouping, sorting. Absent.
18. Reasoning effort per model, with the recommended option marked **Default**
    and the choice carrying over between models that support it. Absent.

## 3. Decisions taken locally

**`⌘J` Continue in AI Chat.** Raycast hands the thread to a separate AI Chat
window. Quick Launch's contract says it is not a chat workspace, so `⌘J` opens
a full-height conversation view of the same thread with the chat history list
beside it. The history, model, and attachments carry over, as Raycast promises.

**Dictation is not built here.** Raycast binds `⌃M` inside Quick AI. Tristan
already owns `local-dictation` as a separate app in `~/Documents/code/house`
that dictates into any focused field from its own global hotkey, so a second
dictation path inside Quick Launch would duplicate a working tool. A client for
that app's control socket was built and then removed, along with its composer
state machine and settings, before this release.

**`⇧⌘R` was already taken.** Quick Launch had Replace Selection on `⇧⌘R`, which
is Raycast's regenerate-on-another-model key. Replace Selection moved to `⇧⌘V`.
It only fires while an answer is active, so a composer field still pastes
normally otherwise.

**Settings home.** Raycast files these under Settings → AI → Commands → Quick
AI. Quick Launch keeps its own rail, so the Quick AI card and the Fallback
Commands card sit in the existing **General** pane, beside History, and Manage
Models opens from Settings → Models.

**Undocumented gaps left alone.** Raycast never documents the Tab hint's visual
form, whether Quick AI's composer is multi-line, or a per-surface list of
response actions. Those were built to fit Quick Launch's existing surface
rather than invented from nothing.

## 4. Behaviours to match exactly

- `Tab` from Root Search always opens Quick AI, with text, without text, and
  regardless of what the fallback command list holds.
- Text handed over by `Tab` is submitted in the same gesture, not staged for
  editing.
- `↵` on a response pastes into the previously focused app unless Primary
  Action is set to copy.
- Follow-ups are a conversation, not a single shot.
- Regenerate same model `⌘R`, different model `⇧⌘R`.
- New chat `⌘N`; browse recent chats `⌘[` and `⌘]`.
- A message over 10 lines, or a comparably long single paragraph, collapses;
  shorter messages are always shown in full.
- Code blocks scroll sideways by default and wrap only when toggled.
- Auto-new-chat options and order: 5 minutes, 10 minutes, 15 minutes, 30
  minutes, 1 hour, always, never.
- Manage Models sort options and order: Brand, Alphabetically, Speed,
  Intelligence, Context Window.
- Ask User Question is always on, with no setting to disable it.

## 6. Build waves

| Wave | Slice | Files |
|---|---|---|
| 1 | Code blocks with language, copy, wrap toggle | `MarkdownRenderer`, `MarkdownTextView`, `CodeBlockView`, answer body |
| 1 | Model profiles, Manage Models, reasoning effort | `ModelProfile`, `ModelPreferenceStore`, `ManageModelsView`, provider settings |
| 1 | Quick AI settings card, Fallback Commands | `QuickSettings`, `SettingsView`, `QuickAISettingsView`, `FallbackCommandsView`, `QuickViewModel` |
| 2 | Add Context menu and `@`, Tab hint, fallback row copy | composer, `OverlayView` |
| 2 | Collapsed messages, `⇧⌘R`, Change Model, `⌘J`, model visibility | transcript, actions, `ConversationView` |
| 2 | Reasoning effort reaches the wire | `OpenAICompatibleService` |
| 3 | Markdown and code blocks in the conversation view | `MarkdownTextView`, `ConversationView` |
| 3 | ~~Dictation~~ | withdrawn, see section 3 |

## 7. Deliberately not built

A general chat workspace, Memory, Projects, Agents, Automations, tool
permissions, credits and usage display, the combined-versus-separate
conversation history setting (it only means something when a second AI surface
exists), and dictation (see section 3).

## 8. Known, not fixed

**Ask User Question landed 2026-09-11.** Section 2.1 item 4 is closed.
`ask_user_question` is offered beside `search_web` whenever the provider is
OpenAI-compatible (`OpenAICompatibleService.askUserQuestionToolDefinition`),
the card is `Sources/Views/AskUserQuestionCard.swift`, and the answer is folded
back into the thread by `QuickViewModel.answerAskQuestion(index:)`. There is no
setting: the tool is always offered, as Raycast documents. A malformed call, or
one with fewer than two usable options, is fed back to the model as an unusable
tool result and the answer continues normally instead of dead-ending.

**DeepSeek tool follow-ups.** DeepSeek requires a reasoning block to be echoed
back on a tool-call follow-up. The `search_web` tool loop does not capture it,
so a DeepSeek answer that uses web search can fail on its second round. This
predates the parity work, is unrelated to the reasoning-effort setting, and is
recorded here rather than quietly fixed.
