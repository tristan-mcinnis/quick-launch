# AI Chat walkthrough, 2026-09-11

Read-only review against HEAD 98fc5aa. Not fixed yet.

I found 22 problems (none repeat the consistency audit). The top four will hit Tristan in normal use:

- A follow-up asked after 5 minutes of reading starts a new chat.
- Add Context › Selected Area leaves the window hidden.
- ⌘Q quits the whole launcher and loses the question being answered.
- Focused Window and Selected Text always fail in the window.

I did not run the app. All findings come from reading the code, the render proofs and the Raycast AI Chat manual. Line numbers are in `Sources/` at HEAD 98fc5aa.

**1. Asking: a follow-up after 5 idle minutes starts a new chat (fix S)**
- `stream()` sets `startsNewChat` from `shouldStartNewConversation` (`QuickViewModel.swift:6538`). That checks `updatedAt` against `newChatInterval`, which defaults to 5 minutes (`:8195-8210`, `QuickSettings.swift:232`).
- Read a long answer for 6 minutes, type a follow-up, and the thread on screen is wiped. The only hint is the placeholder losing "Ask a follow-up…" (`:2206`).
- Reopening the window later also runs `startNewConversation`, which clears the typed draft (`+AIChat.swift:137-139`, `:8220`).
- Why: this breaks the purpose of a chat window. In Raycast, "Start New Chat" applies only to Send to AI commands, not to follow-ups.
- Fix: skip the interval when `isAIChatWindow`. On reopen, keep the last chat and never clear the draft.

**2. Attachments: Selected Area hides the window and never shows it again (fix S)**
- `addContext(.selectedArea)` calls `attachScreenArea`, which calls `prepareForExternalAction`, which runs `orderOut` on the window (`:3740`, `:3912`, `AIChatWindowController.swift:89`). Only the failure path shows it again (`:3914`).
- The command path adds `presentOverlay()` after success (`:3135-3136`), but Add Context does not.
- After a good capture the app has a Dock icon and no window. The Dock icon does nothing because there is no reopen handler. Quick AI's Add Context probably has the same gap.
- Fix: call `recoverFromExternalActionFailure`, or a new "restore" callback, on success too. Add a test.

**3. Lifecycle: ⌘Q quits the launcher, and a stream in progress is lost (fix S)**
- The chat menu's Quit calls `NSApp.terminate` (`AIChatMenu.swift:29,105`). The hotkey launcher dies with it.
- `applicationWillTerminate` does not stop the stream or flush `JSONFileStore` (`AppDelegate.swift:332-346`). `windowWillClose` is not called on quit.
- A question is saved only when its answer ends (`:6729`, `:6842`), so both the question and the partial answer are lost.
- Fix: make ⌘Q close AI Chat, and move Quit to ⌥⌘Q or give it no key. On terminate, call `cancel()` in the window and `flush()` the history store.

**4. Attachments: Focused Window and Selected Text always fail in the window (fix S)**
- The window's view model never gets a `selectionTarget`. Only the launcher's does (`AppDelegate.swift:371,654,1052`).
- So both entries show "No app window was behind Quick Launch. Switch to the app first, then open Quick Launch." (`ScreenshotCaptureService.swift:102`, `:3933`). The row text still says "behind the overlay" (`AddContextEntry.swift:26-27`).
- Fix: record the last app that was frontmost before the window, or hide these two entries in the window.

**5. Model: the model is global, not per chat (fix M)**
- Opening a chat in the rail runs `settings.select(...)` and `save()` on the shared store (`:8257-8259`). This silently changes the default provider for root Ask AI and saved prompts.
- After any ⇧⌘O, `quickAIProviderID` and `quickAIModel` override everything (`:3662-3665`, `:7262`, `QuickSettings.swift:749-759`). So a reopened chat never continues on its own model, which defeats the intent at `:8252`.
- A model change in either window changes the other.
- Fix: keep the model on the chat. The chooser writes the chat's model, and `activeModelID` reads the chat before the global value.

**6. Opening: ⌘J into a busy window stops its answer and wipes its draft (fix S)**
- `adoptAIChatHandoff` cancels the stream, runs `reset([.layers,.thread,.attachments,.input])`, then sets `input = handoff.input`, even when that is empty (`+AIChat.swift:101-122`).
- An answer in another chat stops without warning. The unsent text and attachments are gone.
- Fix: keep the window's draft when the hand-off brings none. If the window is streaming, save the partial answer and say so in the thread.

**7. Asking: the header's New Chat button during a stream loses the question (fix S)**
- `startNewConversation` runs `reset(.thread)`, which ends the stream without `keepStoppedAnswer` (`AIChatWindowView.swift:113-114`, `:7812-7836`).
- The question was never saved, so both it and the partial answer vanish. ⌘N is off while streaming, so only the button reaches this.
- Fix: call `cancel()` first. It keeps the turn, as Escape does.

**8. Lifecycle: closing the window stops the answer (fix M)**
- `windowWillClose` calls `cancel()` (`AIChatWindowController.swift:194`).
- In Raycast the chat keeps going and notifies you when it finishes while minimised. ⌘W halfway through a long vault or tool answer throws the rest away.
- Fix: keep streaming after close (the view model lives on). Show a finished notice or badge.

**9. Find: text across bold or links never matches; the hit is a whole message (fix M)**
- `findMatches` searches the raw Markdown (`AIChatWindowModel.swift:385-391`). The proof shows "**Build** the", so searching "build the" finds nothing, while hidden link URLs do match.
- The highlight covers the whole message, and the view scrolls to the message's head (`:449-458`, `QuickAIThread.swift:539`). In a long answer the match can be screens below.
- The live streaming answer, tool lines and sources are not searched.
- Fix: search the rendered text and highlight the matched range in `MarkdownTextView`, or at least scroll to the match's position.

**10. Two windows, one store: stale thread, mixed-up turns, lost answers (fix M)**
- The window re-reads the store only on `windowDidBecomeKey` (`:185-189`). With the window visible next to the launcher, the rail updates (for example "3 questions") while the thread still shows 2.
- Nothing stops the launcher opening the chat the window holds, from ⌘P or the catalog.
- If both ask at once, the merge appends the other view's turns before this view's (`+AIChat.swift:192-196`). An answer then follows turns it never saw.
- If a chat is deleted while it streams, the answer is dropped with no message (`conversationToStore` returns nil, `:180-181`).
- Fix: refresh on store change, not only on key. Mark a chat that is open in the other view, or hand it over as ⌘J does. Say "chat was deleted" instead of dropping the answer.

**11. Rail: the open chat is not marked (fix S)**
- The keyboard highlight looks like "open". The open chat gets only a ⌘n key cap (`AIChatWindowView.swift:337-372`). In the rail proof, "Kyoto" is highlighted and "Walk me through" is open.
- ⌘1-9 also work with the rail hidden, where no numbers show. Pinned chats take the first numbers.
- Fix: give the open chat its own marker. Show all numbers while ⌘ is held, as Raycast does.

**12. Rail: row actions need the keyboard (fix S)**
- There is no `.contextMenu` and no `.accessibilityActions`. Pin, Rename and Delete exist only as ⌘K with the rail focused (`:614-619`).
- Mouse and VoiceOver users cannot reach them.
- Fix: add a context menu and accessibility actions that call `performRailAction`.

**13. Rail: search is unranked and scales badly (fix S-M)**
- It is a plain substring test over the title and every message, ignoring case and accents, sorted by recency with no ranking. A title hit sorts no higher than a word deep in an answer (`:145-159`).
- CJK works as a substring, but full-width characters are not folded.
- `railItems` is rebuilt, folding all text, about 4-8 times per render (the items, pinned, recent and the row-action titles), and `railDetail` scans history twice per row.
- This is fine at today's 20 chats. At 100-200 long chats my estimate is visible typing lag (not measured).
- "No chats yet" shows while a chat is open with history off.
- Fix: compute once per query, cache the folded text per chat, rank title matches first.

**14. Keyboard: Tab is trapped in the composer (fix S)**
- `QuickAIComposer.swift:119` swallows Tab. `handleTab` returns false in the window.
- The header buttons, the Retry control, source rows and the rail cannot be reached by Tab.
- Fix: when `multiline`, return `.ignored` unless an alias completes.

**15. Accessibility: no spoken cue when an answer ends; wrong field name (fix S)**
- Only errors and the find status are announced (`AIChatWindowView.swift:51-54,210-213`). A VoiceOver user does not hear that an answer finished.
- The composer is named "Ask Quick AI" in the window (`QuickAIComposer.swift:92,125`).
- Fix: announce "Answer ready" when `isStreaming` goes false. Name the field "Message".

**16. Keyboard: ⌘↑/↓, ⌥↑/↓ and Page Up/Down scroll the thread instead of moving the cursor (fix S)**
- The window sends these to `performShortcut`, then `handleThreadKey`, before the text view sees them (`AIChatWindowController.swift:54-60`, `:5287-5292`).
- In an 8-line draft, ⌘↑ cannot jump to the start.
- Fix: in the multi-line composer with text in it, leave these keys to the field.

**17. Attachments: no image paste, no drag and drop, no files (fix M)**
- The clipboard image is offered only when the launcher opens (`AppDelegate.swift:658`). ⌘V of an image in the window does nothing. No view has a drop destination.
- What works: URLs typed in the prompt are fetched (`:6483-6512`), Selected Area (with bug 2), Entire Screen, and what ⌘J carries.
- Raycast allows files, images, clipboard and tabs.
- Fix: ⌘V of an image and a drop of images or text files, read-only and not saved, as the contract already allows for screenshots.

**18. Thread: per-message actions exist only for the newest answer (fix M)**
- Copy (⇧⌘C), Capture to Memory, Open Source (⌘O) and ⌘R act only on the answer on screen (`+ChatTools.swift:101-107,165-170`). There is no hover copy on older answers.
- Fix: a hover or ⌘K action per message for Copy and Capture.

**19. Opening: the window can open on another display (fix S)**
- The frame is restored by autosave name only (`AIChatWindowController.swift:168-171`).
- ⌘J from the launcher on display B brings the chat, and the keyboard, to display A.
- Fix: if the saved frame is on a different screen from the launcher, move it to the launcher's screen and keep its size.

**20. Rail rename: the field sits inside the row's button (fix S, unverified)**
- `AIChatWindowView.swift:340-355` puts the rename field inside the row's button. A click in the field probably fires `openChat`, which moves focus to the composer and leaves the rename half-open.
- Fix: draw the rename field outside the button.

**21. Lifecycle: closing AI Chat removes the menu bar even with Settings open (fix S)**
- `windowWillClose` sets `mainMenu = nil` and `.accessory` without checking for other windows (`:198-199`).
- Settings opened from the chat menu loses its Edit menu (so copy and paste), ⌘Tab and the Dock icon.
- In full screen the header keeps the 76 pt gap for the traffic lights, which are hidden there (`AIChatWindowView.swift:118`).
- Mission Control and Stage Manager: not verified.
- Fix: drop to accessory only when no normal window is still visible.

**22. Continue in pi: nothing happens while streaming (fix S)**
- `continueInPi` returns silently while a stream runs (`:7476-7479`).
- With Keep on Top, the chat window floats over the new Ghostty window.
- Fix: show "Stop the answer first", or stop it and hand off. Lower Keep on Top for the hand-off.

Relevant files (under `./Sources/`): `App/AIChatWindowController.swift`, `App/AIChatMenu.swift`, `App/AppDelegate.swift`, `ViewModels/AIChatWindowModel.swift`, `ViewModels/QuickViewModel.swift`, `ViewModels/QuickViewModel+AIChat.swift`, `ViewModels/QuickViewModel+ChatTools.swift`, `Views/AIChatWindowView.swift`, `Views/QuickAIComposer.swift`, `Views/QuickAIThread.swift`.

Executed but unverified.