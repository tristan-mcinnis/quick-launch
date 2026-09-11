# Quick Launch after v1.5: consistency audit

Read-only audit, 2026-09-11, of what in the rest of Quick Launch became inconsistent, duplicated, stale, or missing after the Quick AI and AI Chat rebuild. Nothing here is fixed yet unless a later commit says so.

The rest of Quick Launch has 22 problems caused by the rebuild. The worst are in the chat lists, the ⋯ menu and the privacy text in the docs. I checked everything by reading the code and the PNGs in `/tmp/quick-launch-render-proof/`. I did not run the app. The working tree is dirty: an uncommitted `AIChatMenu.swift` and a header chip labelled "Open in Chat" are in progress. I audited HEAD and mark the in-progress parts. All paths are under `/Users/user/Documents/code/house/quick-launch/`.

## Ranked findings (most visible first)

**1. ⌘J in Recent Chats moves the wrong chat. (S)**
- Evidence: `Sources/ViewModels/QuickViewModel+AIChat.swift:61-73`. The handoff uses `currentConversation`, the chat behind the list, not the highlighted row.
- Why it matters: ⌘K and the row keys act on the highlighted row (the v1.5.0 A2 fix). The header's ⌘J chip sits right above the list (`quick-ai-recent-chats-pinned-dark.png`).
- Also: no conversation row action offers "Open in AI Chat" (`Sources/Models/ItemAction.swift:266-272`), in the root catalog or in Recent Chats.
- Fix: in Recent Chats, ⌘J hands off the highlighted row. Add "Open in AI Chat ⌘J" to the `.conversation` actions.
- Fixed in v1.5.0 (group G1): ⌘J and the header button move the highlighted Recent Chats row; every chat row offers Open in AI Chat ⌘J.

**2. Four chat lists behave four ways. (M)**
- Root "Quick AI Chats" catalog: searches title, alias and keywords only (`QuickViewModel.swift:1509`). Actions: Continue, Copy Last Answer, Rename, Pin, Delete.
- Recent Chats (⌘P): searches titles and message text (`QuickViewModel.swift:7954-7970`). Same actions.
- AI Chat rail: the same search code copied (`AIChatWindowModel.swift:145-159`). Only Pin, Rename, Delete. ⌘1…⌘9 work here and nowhere else.
- Quick AI ⌘K offers "Browse Chat History ⌘H" (`ItemAction.swift:430,491`; `QuickViewModel.swift:3431,8285`). It leaves Quick AI and opens the root catalog. Recent Chats (⌘P) is not in ⌘K at all.
- Opening a chat from the root catalog always goes to Quick AI (`continueConversation`, `:3072`), never to AI Chat.
- Fix: point ⌘H and "Browse Chat History" at in-surface Recent Chats, and list it in ⌘K. Share one chat-filter helper across the lists. Add message-text search to the catalog.
- Fixed in v1.5.0 (group G1): one search and order (`QuickHistoryStore.matching`) for the catalog, Recent Chats and the rail; ⌘H and ⌘K › Recent Chats (⌘P) open Recent Chats in Quick AI; catalog Return continues in Quick AI, ⌘J opens AI Chat; both lists share one row-action set.

**3. The names do not agree. (S)**
- Catalog title: "Quick AI Chats" (`Sources/Models/LauncherCatalogItem.swift:137`).
- Every Quick AI chat row shows the type "AI Chat" (`Sources/Views/OverlayView.swift:603`, visible in the PNG).
- ⋯ menu: "New AI Chat" and "Recent AI Chats" (`OverlayView.swift:460,470`) act on Quick AI, not on the AI Chat window.
- In-progress chip says "Open in Chat". ⌘K, README and CHANGELOG say "Continue in AI Chat".
- Fix: pick one noun. Suggestion: "Chats" catalog, "Chat" row type, keep "AI Chat" only for the window.
- Fixed in v1.5.0 (group G1): "Chats" catalog, "Chat" row type, ⋯ entries New Chat, Recent Chats, Open AI Chat, and "Open in AI Chat" for the chip and every action.

**4. ⋯ › New AI Chat throws away the chat. (S)**
- `startNewConversation` calls `reset([.thread, .input])` (`QuickViewModel.swift:8220`). Nothing opens and the chat Escape kept is gone.
- "Recent AI Chats" shows `history.prefix(10)` with no explicit sort (the other lists call `QuickHistoryStore.ordered`). It calls `loadConversation`, so ↑ has no last question to recall and the catalog scope is not cleared.
- The menu has no entry to open the AI Chat window.
- Fix: New should call `openQuickAI()` on an empty chat. Recent should call `continueConversation` on the ordered list. Add "Open AI Chat".
- Fixed in v1.5.0 (group G1): New Chat saves the kept chat and opens Quick AI empty; Recent Chats opens in-surface Recent Chats by the ⌘P path; Open AI Chat added.

**5. Auto-copy writes every answer to the clipboard, in both windows. (S)**
- Evidence: `QuickViewModel.swift:6754, 6961, 6349, 6361`. `writeString` adds no transient marker (`Sources/Services/SystemServices.swift:21`), so each answer also lands in Clipboard History.
- The setting is on by default ("Copy result to clipboard automatically", `Sources/Views/SettingsView.swift:500-506`).
- Why it matters: in a chat, every follow-up and every AI Chat turn replaces the user's clipboard.
- Fix: skip auto-copy in AI Chat and on follow-ups, or mark the write as transient. Rewrite the row text.
- Fixed in v1.5.0 (group G2): auto-copy takes only a Quick AI chat's first answer (never a follow-up, never AI Chat), every AI-answer copy is transient via `writeTransientString`, and the row reads "Copy the first answer of each chat automatically".

**6. Settings does not show the chat defaults. (M)**
- Memory, Vault and Skills are on by default in code (`QuickViewModel+ChatTools.swift:21-25`). Only web search has a switch, under Models › Web search (`Sources/Views/ProviderSettingsView.swift:199-209`). Its note mentions only `search_web`.
- The assistant editor offers "Chat defaults" (`Sources/Views/SavedPromptsEditor.swift:295`), which the user cannot see anywhere.
- Keep on Top lives only in UserDefaults (`AIChatWindowModel.swift:79,117`).
- Settings has no pi, tmux or Ghostty status and does not say whether `recall` or the vault lane can run.
- Settings contains no mention of AI Chat or pi at all.
- Fix: add a "Chat" card with the four default-tool switches, Keep AI Chat on top, and a status line for Continue in pi and the tool backends.
- Fixed in v1.5.0 (group G3): Settings › General › Chat has the four chat-default switches (Web search is the one `modelWebSearchEnabled` setting), Keep AI Chat on top on the window's own key, and off-main status lines for Continue in pi and the tool backends.

**7. The Quick AI settings card text is out of date. (S)**
- Evidence: `Sources/Views/QuickAISettingsView.swift`.
- The card also controls AI Chat (model, new-chat interval, clarifying questions) but never says so.
- Primary Action says "Return pastes the answer into the app behind". AI Chat always copies (`QuickViewModel.swift:7629`).
- "Tab opens Quick AI whether…" (`:33`) and the same claim in `Sources/Views/FallbackCommandsView.swift:38-39` are false for math.
- Fix: rename the card to "Quick AI and AI Chat", or add a note. Correct the Tab text.
- Fixed in v1.5.0 (group G3): the card is "Quick AI and AI Chat", Primary Action says AI Chat always copies, and both Tab texts say math and conversions answer in place.

**8. Chat history keeps only 20 unpinned chats, and Settings does not say so. (S)**
- Evidence: `Sources/Models/QuickSettings.swift:229`; `Sources/Services/QuickHistoryStore.swift:88`.
- The History card still says "Keep quick-action history" and has no limit control (`SettingsView.swift:797-812`).
- Why it matters: 20 is tight for a window with a chat rail and ⌘1…⌘9.
- Fix: rename the row "Keep chat history" and add a limit picker.
- Fixed in v1.5.0 (group G3): "Keep chat history" plus a Chats to keep picker (20, 50, 100, 200; 100 for new installs, a stored limit kept); pinned chats are never pruned.

**9. AI Chat as a fallback command drops the typed text. (S)**
- AI Chat is in the fallback choices (`QuickViewModel.swift:899, 3264`). `runFallbackCommand` sets the input, then `openAIChatWindow()` clears it (`QuickViewModel+AIChat.swift:77-81`).
- Fix: pass the text as the handoff input, or remove AI Chat from the fallback choices.
- Fixed in v1.5.0 (group G1): the fallback passes the typed text as the handoff input, so the window opens a new chat with it as the draft.

**10. The Ask AI row can say the wrong thing for math. (S)**
- The row is always listed (`QuickViewModel.swift:1633-1640`). Its detail says "“2+2” to DeepSeek… ⇥ opens Quick AI" (`:1138-1146`), but Tab and Return answer inline.
- Fix: when `localAnswer(for:)` matches, change the detail.
- Fixed in v1.5.0 (group G2): with a local answer the row reads "Answered here, not sent to <model>" and draws no ⇥ hint (`typedTextHasLocalAnswer`, the same rule as Tab).

**11. The Welcome text is stale. (S)**
- Evidence: `Sources/Views/WelcomeOverlayView.swift:28-37`; `slate-welcome-dark.png`.
- It says "run a quick action… copies to your clipboard automatically". It says nothing about Tab to Quick AI, ⌘J, or the tools.
- Fixed in v1.5.0 (group G3): Welcome now reads: your hotkey opens search, Tab asks Quick AI, ⌘J opens AI Chat, @ adds context, tools can read your memory and the vault.

**12. The menu-bar menu shows the wrong hotkey. (S)**
- "Open Quick Launch" shows ⌃Space. The default is ⌥Space and it can be changed (`Sources/App/AppDelegate.swift:1236-1242`; `QuickSettings.swift:126-127`).
- "AI Chat" sits between Settings and Caffeinate.
- Fix: read the hotkey from settings, and reorder the menu.
- Fixed in v1.5.0 (group G2): `StatusMenu` builds the menu from settings on every right-click, so "Open Quick Launch" shows the configured hotkey, and AI Chat follows it before Settings and Caffeinate.

**13. ⌘P means two things. (S)**
- In Translator, ⌘P is Target language (`translator-dark.png`; `README.md:33`). In Quick AI and AI Chat, ⌘P opens the chat list.
- The v1.5 check that "⌘P is free in every key table" missed Translator. `docs/primitives.md` says the Translator uses the same key meanings.
- Fix: move the Translator key, or document the exception.
- Fixed in v1.5.0 (group G4): Target language moved to ⌘T (free in every key table); ⌘P does nothing in the Translator, and the chip, tooltip and footer read one `TranslatorKey` table.

**14. The ⌘K palette labels chat actions "Answer". (S)**
- `Sources/Views/OverlayView.swift:1113` falls back to "Answer" for every result action. New Chat, Tools, Delete Chat and Continue in AI Chat all show it.
- Fixed in v1.5.0 (group G1): chat actions have their own detail line; the fallback is `ResultAction.paletteGroup`, "Chat" or "Answer".

**15. Keep on Top uses the pin glyph. (S)**
- Evidence: `Sources/Models/QuickAISurfaceAction.swift:54`.
- Pinned chats use the same glyph, so the pin in the AI Chat header is ambiguous.
- Fixed in v1.5.0 (group G2): Keep on Top uses `square.3.layers.3d.top.filled` (Stop is `square.3.layers.3d.slash`) in `⌘K` and the AI Chat header; the pin is only for pinned chats.

**16. Translator still uses the old look. (M, low priority)**
- Uppercase labels (SOURCE, CHINESE (SIMPLIFIED)), a footer well with a status dot, and its own `FooterHintView` (`Sources/Views/TranslatorView.swift:82,129,262`).
- Quick AI now has a header and composer and no footer. `overlay-answer-dark.png` does not use the old look.
- The labels are defensible for a two-pane tool. At least reuse the launcher's hint component.
- Fixed in v1.5.0 (group G4): `FooterHintView` removed; the footer is the launcher footer's strip (status dot, `meta` context, shared `KeyHint`s, launcher `FooterHint` type, `Space.row` gaps); layout and section labels kept.

**17. Dead code from the old conversation view. (S)**
- `isConversationHistoryPresented` and `toggleConversationHistory` have no view and no caller (`QuickViewModel.swift:156, 8276`). `AppDelegate.swift:1366` still observes the flag.
- Old comments refer to an "overlay answer" (`Sources/Views/CodeBlockView.swift:140`; `Sources/Views/MarkdownTextView.swift:9`).
- Fixed in v1.5.0 (group G1): the flag, the toggle and the AppDelegate observation are deleted; both comments now describe the thread and root-search answers.

**18. README describes the pre-v1.4 overlay. (M)**
- `README.md:7-9`: "streams into the overlay and is copied… not a full chat workspace".
- `:77`: "On-demand conversation transcript".
- `:154`: "stop button… trailing menu for… history".
- `:160-163`: "small footer under each completed reply… 44-point targets… trailing menu can show the current conversation".
- `:167`: "Clipboard History stores text only".
- `:168, 284`: "Settings → Catalogs". The tab is "Clipboard & Capture".
- `:226, 259`: "Settings → Prompts". The tab is "AI Commands".
- Fixed in v1.5.0 (group DOCS): the intro, Use steps, reopen and answer-key text, input row, chat history and auto-copy lines describe Quick AI and AI Chat; Clipboard History keeps text, images, rich text, and files; tab names are Clipboard & Capture, AI Commands, and Items; the Translator key is `⌘T`; screenshots go to the Vision model setting (DeepSeek by default), not only to local MLX; Clean Up and Translate show their result first (they never replace the selection on their own); chat history is its own owner-only file, not `UserDefaults`; the leftover "overlay" wording names the launcher or the ⋯ menu; the privacy list says what reaches the provider and what chat history keeps.

**19. README contradicts itself on math. (S)**
- `README.md:242` says math asked from the Quick AI composer shows in root search. `README.md:44` and the CHANGELOG say it stays in the chat as a "Local answer".
- Fixed in v1.5.0 (group DOCS): the math paragraph now says root search answers in place and the Quick AI composer keeps a "Local answer" in the chat, never a turn and never sent to a model.

**20. `docs/product-scope.md` is wrong on privacy and scope. (M)**
- `:105` says "API actions send only the text used by that action". This is false: memory, vault and skill results and the chat history go to the provider.
- `:85` says OpenAI-compatible providers "do not share a tool-calling loop". False.
- `:30`: "does not need… a full chat workspace".
- `:50`: "Escape closes the panel from anywhere".
- `:94`: clipboard history "text-only".
- The catalog table has no Chats and no AI Chat.
- Fixed in v1.5.0 (group DOCS): the privacy section lists everything a question sends (the whole chat, instructions and skills, Add Context and selection text, web and page text, tool results) and what chat history keeps; the tool loop, the AI Chat boundary, Escape, the footer, and the clipboard kinds are correct; Chats and AI Chat are in the catalog table, and the Quick AI row names `Tab`; the Screenshots catalog and the Translator window are no longer called future work; one line points to the attachments spec.

**21. `docs/primitives.md` has the wrong key contract and privacy text. (M)**
- `:60`: ⎋ "Close the overlay from anywhere". False in both Quick AI and AI Chat.
- `:80`: "⌘1…9 is deliberately unused". The AI Chat rail uses them.
- The key table has no ⌘J, ⌘P, ⌘H, ⌘\, ⌘F, ⌘O, ⌥⌘K, ⌥⌘M, ⌥⌘A or ⌘W.
- `:41`: "Tool window" lists only the Translator.
- `:91`: "footer is the only place that explains keys". Quick AI has no footer, and Recent Chats shows key hints in the list.
- `:146-147`: the same false privacy and "text" clipboard claims as item 20.
- Fixed in v1.5.0 (group DOCS): the key table has `⌘P`, `⌘H`, `⌘J`, `⌘\`, `⌘F`, `⌘1…9` (AI Chat), `⌘O`, `⌥⌘K`, `⌥⌘M`, `⌥⌘A`, `⇧⌘O`/`⇧⌘R`, `⌘W`, `⌘T` (Translator), `⌥⌘T`, `⇧⌘M`, `⌘L`/`⇧⌘W`, and `⌥⌘P` and `⌥⌘C` for both chat views; Escape steps back one layer per view; the number-key note, the tool windows (Translator and AI Chat), the footer, Settings, and the privacy text (the chat, tool results, and saved Add Context text reach the provider) match the code.

**22. `docs/quick-ai-parity-20260911.md:85-88` is superseded. (S)**
- It still says ⌘J opens a conversation view because the contract forbids a chat workspace. It has no superseded note.
- Fixed in v1.5.0 (group DOCS): a superseded note under the `⌘J` decision and a pointer in the status paragraph; sections 4 and 7 note the clarifying-questions setting and AI Chat as the second surface.

Items 1 to 5 are the ones users will hit. Items 18 to 21 are docs, but items 20 and 21 make privacy claims the tools now break.