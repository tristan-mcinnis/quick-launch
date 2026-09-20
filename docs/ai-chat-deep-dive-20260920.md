# AI Chat deep dive, 20 September 2026

Written against commit `43d9d25`, which is the build installed in
`/Applications/Quick Launch.app` (stamped `QuickLaunchBuiltFromCommit`). The
two performance fixes of 18 September are already in it, so everything below
is a cost that survives them.

Every claim comes from reading the source or measuring this Mac. Where I could
not verify something I say so. Nothing here was changed; this is a read.

---

## Short version

Seven things, in the order they cost you something:

1. All three markdown caches fail while an answer streams. The live answer
   evicts every finished one, so a long thread re-parses and re-measures itself
   from scratch about thirty times a second.
2. The archive rewrites the whole conversation file, with two `fsync` calls,
   every 800 characters, and the token loop waits for it.
3. `NSApp.windowsMenu` is never set, so macOS never adds its own Move & Resize
   menu. That is why you cannot put the window on half the screen.
4. The window re-centres itself on the launcher's display every time it opens.
5. The scope pill cannot help you in an ordinary chat. It can only turn the
   tools off, it does not change its own label when it does, and drawing it
   recomputes the context policy about nine times per keystroke.
6. The composer placeholder says "/ for commands" and typing `/` opens nothing.
7. The sidebar hotkey you asked for already exists. It is `⌃⌘S`.

Items 1, 2, 5 and 6 are defects. Items 3 and 4 are decisions that no longer fit
what you want. Item 7 is a discovery failure, which is its own kind of defect.

---

## 1. The composer chrome

### What the pill actually does

The pill and the line under it are drawn by `Sources/Views/ChatPreSendControls.swift`,
the only view that draws them, mounted from `Sources/Views/QuickAIComposer.swift:84-86`
so both Quick AI and AI Chat get it. The words come from
`Sources/ViewModels/QuickViewModel+ChatCommands.swift:124-153`.

The decision behind them is `ContextPolicy`
(`Packages/HouseChatCore/Sources/HouseChatCore/Context/ContextPolicy.swift:295-308`).
Its rule is simple, and it is not what the pill suggests:

- A chat with no attachment, now or earlier, **already allows every tool**.
- A chat that carries a source **withholds** them, until the question names an
  outside target ("web", "vault", "online", "上网") or the pill is clicked.

So in an ordinary chat the pill reads "Standard chat" and the line reads
"No source attached; the tools may be used." That is the good state, and it is
the state you are in almost always.

Now the part that matters. In that same ordinary chat, `toggleContextScope()`
(`QuickViewModel+ChatCommands.swift:170-173`) sets the override to `.sourceOnly`,
which sets `allowsExternalRetrieval = false`, which empties `gatedTools`
(`Sources/Services/Chat/ChatContextGate.swift:99-102`).

**In a chat with no attachment, the only thing the pill can do is turn the
tools off.** It cannot improve anything. Clicking once breaks the chat,
clicking twice repairs it.

It is worse than that. The `guard hasAnySource else { return "Standard chat" }`
at `QuickViewModel+ChatCommands.swift:125-126` runs before the override is
consulted, so after you click, **the pill still reads "Standard chat" while
every tool is withheld.** Only the small grey line underneath changes, from
"the tools may be used" to "the tools are unavailable." The control does not
report the state its own click created. That is a defect, and it is why the
toggle felt incoherent to you.

One more thing, and it matters for your "the model should decide" instinct.
When the tools are withheld the model is never told they exist. `toolOverride`
is the gated set (`QuickViewModel.swift:8858`), which becomes an empty
`ChatToolbox` and drops the `search_web` function entirely (`:9729-9772`). The
model cannot decide it needs a tool. The gate decides for it before the
request leaves the Mac.

### What the destination label does

"Will send to DeepSeek API" comes from `Sources/Services/Chat/ChatRouteResolver.swift:116`.
The same property has four other cases (`:109-125`, `:244`):

- `"No vision model: this image cannot be sent"` (a block, not a note)
- `"No model available"` (a block)
- `"X needs an API key. Add it under Settings › Models."` (a block)
- `"Only on this Mac"` (a local route)
- `"DeepSeek cannot read images; will send the image to <other>"` (a silent
  provider switch)

Five of six say something you want to know. The sixth, the one you see every
single time, says nothing. Deleting the whole line would throw away the five
that earn their place.

The per-answer record already carries the route independently
(`Sources/Views/ChatContextRecordView.swift:212-227`, drawn from
`Sources/Views/QuickAIThread.swift:404`). That is the "DeepSeek API ·
deepseek-flash" row in your screenshot. So the composer label is genuinely
redundant in the steady state, and only there.

### What I recommend

Delete the pill outright, with `contextScopeLabel`, `contextScopeDetail`,
`contextScopeOffersWidening` and `toggleContextScope`.

Keep the destination line, but render nothing when there is no warning. In an
ordinary cloud chat it disappears; a blocked route, a local route or a vision
fallback still speaks.

**That second half is not optional.** The composer row is the only pre-send
surface for a route warning on a text-only turn. `attachmentRoutingLine`
(`QuickViewModel+Attachments.swift:390-404`) draws only inside the attachment
strip (`Sources/Views/AttachmentChip.swift:673`), so with no attachment a
missing API key would first appear as an error *after* you press Return.
Deleting the line outright would cost you that.

Keep the source detail line only while a source is attached.

### Tools always available

Your ask is "tools should always be able to be used". Today they always are,
except when a source is attached. The grounded case is the one to decide.

Smallest honest change: leave `ContextPolicy` alone, so it still computes
`allowsExternalRetrieval` for the per-turn receipt, and open the gate in
`ChatContextGate` instead. `gatedTools` (`:99-102`) returns `enabled`
unconditionally; `allowsWebSearch` (`:122-124`) returns true. Then delete the
pill.

Keep the attachment scoping. `ChatContextPipeline.scopedMessages`
(`QuickViewModel.swift:8763-8766`) strips out-of-scope attachment payloads from
the request copy, which is what actually makes "summarise this PDF" read the
PDF rather than the whole chat. It survives untouched, so source-first reading
is not what you are giving up.

What you give up is the automatic withhold. If you want that judgment back, it
belongs in the system prompt, which today never changes
(`QuickViewModel.swift:9762` always passes `settings.systemPrompt`). A line
saying "a source is attached, answer from it unless the question needs outside
evidence" hands the call to the model, which is what you actually asked for.

Do not open the gate and keep the strings. That makes the UI lie.

### The contract you are overriding

`docs/chat-harmonization-plan-20260917.md:23` is an implementation contract you
approved on 17 September:

> Disable memory/vault/web/skill loading in both offered tools and execution
> [...] unless the question requests broader evidence or the user selects
> Broader search. Keep a visible Attached sources / Broader search control.

And `CLAUDE.md:85-87`:

> Show the effective destination before Send and record it per answer.

You are entitled to reverse both. I am flagging it because the plan says
"approved by Tristan" and a reader later will want to know this was deliberate.
Both the plan doc and `CLAUDE.md` need a dated amendment in the same change,
not a silent edit.

### Tests that break

Pill strings: `Tests/ChatContextRenderProofTests.swift:69-72` and `:85-88`.
That file also renders the composer to PNG, so four render proofs change:
`chat-context-composer-min-{dark,light}.png` and
`chat-context-broader-search-{dark,light}.png`.

Gate behaviour: `Tests/ChatContextGateTests.swift` at `:14-26`, `:41-53`,
`:83-96`, `:98-110`, `:112-123`. Five of nine cases, all asserting
`gatedTools.isEmpty`. `ContextPolicyTests.swift` stays green as long as the
policy itself is left alone.

Destination label: only breaks if the `ChatDestination` seam is deleted, not if
the composer row is made conditional. `Tests/DurableChatTurnTests.swift:69-76`,
`Tests/QuickViewModelTests.swift:435-447`, `Tests/AttachmentFlowTests.swift:485-487`,
`Tests/ChatRouteResolverTests.swift:188, :206, :297`,
`Tests/ChatModelFreezeTests.swift:43`. A warning-only label keeps all of them
green.

---

## 2. Latency

You are right, and it is not the network. The answer in your screenshot took
0.79 s to first token, which is DeepSeek. What follows is the app.

### 2.1 All three markdown caches fail during streaming

There are three caches in `Sources/Services/MarkdownRenderer.swift`, and
streaming defeats every one of them.

**The segments cache holds one entry** (`:30`):

```swift
@MainActor private static var segmentsCache: (source: String, segments: [AnswerSegment])?
```

`Sources/Views/MarkdownTextView.swift:49` calls `cachedSegments(markdown)` from
inside a SwiftUI `body`. `QuickAIThread.swift:95` renders
`ForEach(viewModel.conversationMessages)`, and each assistant message draws a
`MarkdownTextView` (`:583`). One pass over N answers asks for N different
strings in a row, each ask missing because the cache holds the previous one.
Every miss runs `Document(parsing: markdown)`, a full swift-markdown AST parse
(`Package.swift:8`). **The hit rate is zero for any thread longer than one
message.**

**The render and height caches are evicted by the answer in flight, and this is
the bigger half.** `renderCache` (`:152-163`) and `heightCache` (`:195-215`) are
24-entry arrays. Every 33 ms flush (`QuickViewModel.swift:908`) produces a new
`output` string, and `ProseSegmentView.sizeThatFits`
(`MarkdownTextView.swift:175-216`) routes through `proseHeight` → `cachedRender`,
so **each flush appends a new entry to both caches**.

After about 24 flushes, which is under a second of streaming, both caches hold
nothing but intermediate snapshots of the answer currently arriving. Every
finished answer above it has been evicted. A miss on a finished answer costs a
full `render()` (CommonMark parse plus `AttributedStringWalker`) *and* an
`NSAttributedString.boundingRect` text layout.

So during streaming, a twenty-message thread re-parses and re-measures all
twenty finished answers, thirty times a second, from scratch. That is your lag.
It grows with thread length, which matches "it feels a bit too laggy" rather
than "it is slow".

Two things stop SwiftUI from skipping the work: `QuickAIThread.swift:393`
passes `instanceID: "message-\(message.id.uuidString)"`, a freshly allocated
String every pass, and `:588-596` passes closures. The authors already recorded
the behaviour in a comment at `MarkdownRenderer.swift:148-151`: "the overlay
re-evaluates its body for every state change".

Scrolling drives the same loop. `@State threadGeometry` is written from
`.onScrollGeometryChange` (`QuickAIThread.swift:182-198`) and `scrollPhase` from
`.onScrollPhaseChange` (`:199-206`), so every scroll frame re-runs the thread
body too.

The fix is three parts, all small: give `segmentsCache` the bounded-array shape
the other two have; keep the streaming answer out of the shared caches, or key
the caches by message id so a live answer cannot evict finished ones; and stop
allocating a fresh `instanceID` per pass.

### 2.2 The archive rewrite blocks the token loop

`QuickViewModel.swift:8991-9011`. Every 800 characters of streamed output, the
code does this **inside** the `for try await delta in stream` loop:

```swift
_ = try await chatArchive.checkpoint(...)
```

There is no append log and no partial update. `performTurnUpdate`
(`Sources/Services/Chat/ChatArchive.swift:302-331`) reads and decodes the whole
conversation file, mutates one turn, and re-encodes the whole thing
pretty-printed with sorted keys (`ConversationArchive.swift:204`). Then
`AtomicFile.write` (`AtomicFile.swift:26-70`) writes a temp file, `fsync`s the
file descriptor (`:53`), renames, and `fsync`s the directory (`:67`).

**Two fsyncs per checkpoint, and the token loop awaits them.**

A 4,000-character answer in a 17 KB chat is five full read-decode-reencode-write
cycles and ten fsyncs, interleaved with the tokens arriving. Then the terminal
`completeTurn` (`:9053`), then `persistAnsweredConversation` rewrites all 75,621
bytes of `chat-history.json`.

The archive work itself is off the main thread (`ChatArchive` and
`ConversationArchive` are actors, `JSONFileStore.save` hops to a `.utility`
queue at `JSONFileStore.swift:101-109`). That is not the problem. The problem is
that the consumer of the stream waits for it, so disk latency lands directly in
token rendering.

This is the second half of your lag, and it stacks with 2.1: both fire during
streaming, and both get worse as the chat gets longer.

Fix: do not await the checkpoint. Fire it as a detached task with the last one
cancelled, or checkpoint on a wall-clock interval rather than a character count,
or both. The durability guarantee you actually need is "an interrupted answer is
not lost", which a debounced background write satisfies.

### 2.3 The scope pill recomputes the context gate about nine times per keystroke

`ChatPreSendControls.swift` reads `composerContextEvaluation` indirectly at
lines 32, 33, 60, 65, 84, 85, 86 and 88, and line 88 reads it twice.
`accessibilityValue`, `accessibilityHint` and `help` all take `String`
arguments, so they evaluate eagerly during body construction. Nothing is
memoised (`QuickViewModel+ChatCommands.swift:95-105`).

Each evaluation scans every message (`conversationHasSources`, `:176-178`) and
runs `ContextPolicy.classify` (`ContextPolicy.swift:369-410`), which lowercases
the draft, tokenises it with a `CharacterSet.alphanumerics.contains` per unicode
scalar (`:448-461`), then runs **five `terms.sorted()` calls** (`:376`) sorting
sets of 20 to 30 strings into fresh arrays.

It reads `input`, so it re-runs on every character typed. That is roughly **45
set sorts and about 1,000 term tests per keystroke**, to render a control that
cannot help you.

**Deleting the pill deletes all of it.** The two things you asked for are the
same change.

### 2.4 The route resolver runs six or more times per pass

`QuickViewModel+Attachments.swift:381-384` exposes three properties that each
call `resolvedNextRoute()`, and `ChatPreSendControls.swift:100-102` reads all
three. `QuickAITitleBlock.swift:44` and `:52` read `activeModelDisplay` twice
more, `QuickAIThread.swift:245` a third time inside `accessibilityLabel`, and
`activeModelDisplay` (`QuickViewModel.swift:3089-3100`) calls the resolver
again.

Each call (`QuickViewModel+Attachments.swift:356-376`) walks every message's
`attachmentRefs`, so it scales with conversation length.

The 18 September Keychain fix holds: `QuickViewModel.swift:934-939` caches
`hasAPIKey`, so this is no longer hitting the Keychain. It is still six-plus
walks of the whole conversation per pass.

### 2.5 Collapse policy is quadratic over visible pills

`MessageCollapsePolicy.estimatedLineCount` (`Sources/Models/MessageCollapse.swift:30-36`)
splits on newlines and counts graphemes. `isCollapsible` (`:115`) and
`displayedText` (`:120-122`) both call it, so each question pill hits it two or
three times (`CollapsibleMessageText.swift:39, :84`).

Worse, `QuickAIThread.swift:332` calls `showsCollapseShortcut(for:)` for every
user pill, which resolves `keyboardToggleMessageID`
(`QuickViewModel.swift:10577-10579`) by re-scanning the whole message array each
time. Cost per pass is visible pills times user turns.

### 2.6 First open builds a second view model

`Sources/App/AppDelegate.swift:1703-1733`. The AI Chat controller is lazy. The
first open constructs an entire second `QuickViewModel`, an 11,197-line class,
wired to every service: application catalog, launcher catalog, web search, vault
search, page reader, speech, journal, screenshot service, screen awareness,
document extractor, plus `SkillLibrary()` and `PiHandoffService()`.

It also constructs `SharedDocumentExtractor()` and a second
`ScreenshotTextIndex` on the same main-thread call.

Then `prepareWindow()` (`AIChatWindowController.swift:609-659`) builds the
NSWindow, the toolbar and the `NSHostingController`.

And the ordering makes it worse. `AIChatWindowModel.open()` (`:180-192`) calls
`chat.openLatestChat()` **before** `window?.showWindow()`, so the first layout
parses, renders and measures every message in the opening viewport
synchronously, with 2.1 in full effect, before anything reaches the screen.

All on the main thread, on the click meant to show a window. Once per app
launch, so it is the "first open is slow, then fine" shape.

### 2.7 The activation dance

`Sources/App/AppActivation.swift:27-45`. The app is `LSUIElement`
(`Info.plist:29-30`), so it lives as a menu-bar app. Opening the chat flips it
to `.regular`, then runs this:

- poll up to 50 times at 20 ms waiting for `NSApp.isActive` (up to **1 second**)
- activate the Dock
- sleep 60 ms
- bring the window to the front again

The guard at `:31` is `guard !wasRegular else { return }`, so an app that is
already regular skips both the policy change and the dance. But
`settleAfterClosing` (`:52-59`) flips back to `.accessory` when the last normal
window closes, so **the normal open-and-close cycle pays it every time**.

It is a workaround for a real macOS problem (an accessory app that becomes
regular keeps showing the previous app's menu bar), but it is up to a second of
focus bouncing through the Dock on a window open.

Two nuances worth knowing, both of which avoid it. A minimised window still
counts as shown (`WindowPresence`, `:83-102`), so minimising instead of closing
keeps the Dock icon and skips the dance next time. And with Settings already
open the app is already regular, so the chat opens clean.

### 2.8 Startup decodes every chat twice

`ConversationArchive.list()` (`ConversationArchive.swift:288-348`) scans the
directory, reads every `.json` in full (`:307`), runs a complete decode over
every turn, tool round and attachment record (`:316`), then discards all of it
except id, title, surface, dates and turn count. Its own doc comment at
`ConversationSummary:109` claims it shows a list "without loading every turn's
text". The code does the opposite.

`ChatArchive.readableRecords()` (`ChatArchive.swift:105-123`) then loops those
summaries and calls `load(id:)`, reading and decoding each file a **second**
time (`ConversationArchive.swift:268-283`).

So hydration is 2N reads and 2N full decodes. Measured at 25 chats: 50 reads,
about 284 KB, low tens of milliseconds. Fine today, and it runs once from
`AppDelegate.swift:444`. After that the sidebar is free, reading an in-memory
array (`QuickStore.swift:25`); opening the chat list touches no disk.

Filed as a scaling note, not a current cost.

### 2.9 Smaller things

`QuickViewModel+AIChat.swift:296-299`: every time the chat window becomes key,
`currentExternalTarget()` runs `CGWindowListCopyWindowInfo` with
`.optionOnScreenOnly` (`SelectedTextService.swift:61-67`), a synchronous
WindowServer round trip allocating a dictionary per on-screen window. Single-digit
milliseconds, on the click-into-window path.

`ClipboardHistoryStore.swift:77` polls the pasteboard every second, app-wide,
and the class is `@Observable` (`:5`). I did not trace whether a chat view reads
any of its observed properties, so I cannot say whether it invalidates the chat
body once a second. Worth checking while fixing 2.1.

The chat list rail is a plain `VStack` in a `ScrollView`, not a `LazyVStack`
(`AIChatWindowView.swift:264-292`), and `section()` (`:357-368`) iterates all
rows. Every row calls `railDetail` (`AIChatWindowModel.swift:233-240`), which
uses `Calendar.current` and a `Date.formatted` FormatStyle, and builds an
interpolated accessibility label (`:426-429`). The body reads `railItems` four
times (`:261-263`, `:305`). An arrow key rebuilds every row. Only costs you
while the rail is open.

`QuickAIThread.swift:402-428` rebuilds a `ChatAnswerReceiptSummary` for every
visible answer each pass; the init (`ChatContextRecordView.swift:212-308`)
allocates about ten strings and makes three ICU-backed `Int.formatted()` calls.
`QuickViewModel.swift:3039-3044` builds `Set(settings.savedPrompts.map(\.alias))`
on every `title(of:)` call. `CodeBlockView.swift:28-39, :298, :303` splits on
newlines and builds a fresh `AttributedString` per pass.

### What is already clean

Worth saying, so the fixes stay targeted. Thumbnail decoding is fixed
(`AttachmentChip.swift:324-365`, `NSCache`, sampled key). The Keychain read is
cached (`QuickViewModel.swift:934-939`). `ChatArchive` is an actor
(`ChatArchive.swift:37`). History saves go to a background queue
(`JSONFileStore.swift:101-109`). There is **no** `FileManager`, `DateFormatter`,
regex or `Process` call on any body path in the chat views, and no polling
publisher runs inside the chat view tree.

Observation scope is also better than it looks for an 11,000-line view model.
`AIChatWindowView.body` does not read `output` or `conversationMessages`, so the
window root does not re-run per token. It does read `chat.settings`, and
`QuickStore.settings` (`QuickStore.swift:23-24`) is one stored property holding
the whole struct, so any settings write invalidates the whole window body.
`QuickAIThread.body` re-runs per flush and per scroll frame;
`QuickAIComposer.body` and `ChatPreSendControls.body` re-run per keystroke.

### Ranked

1. **Markdown caches** (2.1). All three fail during streaming; the render and
   height caches being evicted by the live answer is the biggest single cost,
   and it scales with thread length.
2. **Archive checkpoint awaited in the token loop** (2.2). Two fsyncs every 800
   characters, stalling token rendering.
3. **Activation dance plus the first-open lazy build** (2.6, 2.7). Up to a
   second, on every open.
4. **Context gate recomputed nine times per keystroke** (2.3). Free to fix, and
   deleting the pill deletes it.
5. **Six-plus route resolutions per pass** (2.4).
6. **Quadratic collapse scanning** (2.5).
7. `CGWindowListCopyWindowInfo` per focus gain, eager rail rows, receipts and
   small allocations (2.9).

Items 1 and 2 are the streaming lag. Items 3 to 6 are the typing lag. They are
different problems with the same symptom.

---

## 3. Storage and memory

### Chats are JSON files, not SQLite

At `~/Library/Application Support/Quick Launch/`:

```
chats/<slug>-<10 hex of sha256(id)>.json    25 files, 142,372 bytes of content
                                            mean 5.7 KB, median 5.3 KB, largest 17 KB
chat-assets/<kind>/<xx>/<sha256>            4.8 MB, content-addressed
chat-history.json                           75 KB, bounded legacy UI cache, not authority
chat-history.pre-archive.json               one-time rollback copy
```

One envelope per conversation, `{format, schemaVersion, savedAt, conversation}`
(`ConversationArchive.swift:35-77`), pretty-printed with sorted keys. The whole
body is inline: every turn's text, receipt, tool rounds, timings and attachment
records.

**This is the right choice and I would not change it.** 25 chats at 5.7 KB
average is nothing, and after one startup scan everything is served from RAM.
SQLite would add a dependency, a schema, a migration and a WAL to babysit, in
exchange for making a 142 KB read faster. You asked whether it is "something
ridiculously fast and low latency", and the honest answer is that at this size,
a flat directory of small JSON files *is* the fast option. Revisit at a few
thousand chats.

The app does use SQLite, for screen history only (`ScreenHistoryStore.swift:44`,
`CoastLegacyReader.swift:189`). Clipboard history is JSON too
(`ClipboardHistoryStore.swift:39, :63`). That split is correct: screen history
is large and queried, chats are small and listed.

The design itself is sound: atomic writes, fail-closed decode, unknown fields
carried forward, tombstoned deletes. The problem is not the format. It is the
write pattern in 2.2.

Unrelated but sitting in the same directory: the screen history WAL is 3.5 MB
against a 168 KB database, last checkpointed 19 September.

### Where the disk actually goes

```
ClipboardBlobs/     69 MB    (85% of the app's 81 MB)
chat-assets/       4.8 MB
Screen History     2.7 MB
chats/             142 KB
```

Chat is not your disk problem. Clipboard history is, if anything is.

### Memory

Measured on the running process (pid 35223, up 22 hours):

```
footprint       204 MB
MALLOC_SMALL    102 MB dirty, 164 MB reclaimable
MALLOC_LARGE     33 MB dirty
CoreAnimation    17 MB across 424 regions
RSS             387 MB
```

204 MB for a launcher is high. Two caches have **no eviction at all**:

- `AppIconCache` (`Sources/Services/AppIconCache.swift:8`) is a plain
  `[String: NSImage]`. No count limit, no cost limit, not an `NSCache`, no
  memory-pressure handling. One `NSImage` per app path ever seen, released only
  by an explicit `forget(path:)` at `:17`.
- `ScreenshotTextIndex` (`Sources/Services/ScreenshotTextIndex.swift:30-31`)
  holds `entries: [String: Entry]` with the full OCR text of every screenshot,
  plus `normalizedCache: [String: String]` holding a folded copy of the same
  text. Neither is bounded. 218 KB on disk today, roughly doubled in RAM.

Bounded but with high ceilings: `ScreenshotThumbnailCache` is an `NSCache` at
300 items / 64 MB (`ScreenshotTextIndex.swift:185-190`); `AttachmentSessionStore`
is LRU at 2,000,000 characters and 64 MB of image bytes
(`ChatAttachment.swift:307, :310`). `ChatSearchIndex` (`ChatSearch.swift:843+`)
keeps a folded copy of every chat's title, questions and answers once search is
used, pruned only to live chat ids.

What is **not** the problem: `store.history` holds every conversation
uncapped (`QuickViewModel.swift:11063-11066`), but at 142 KB of JSON that is a
few hundred KB live. `QuickMessage.attachments` holds references, not bytes, so
chat records carry no image data. Two full `QuickViewModel` instances live at
once once the chat has been opened (`AppDelegate.swift:1706`), which is
deliberate but not free.

The 164 MB reclaimable in `MALLOC_SMALL` is the signature of allocation churn
that malloc has not returned to the OS. The markdown churn in 2.1 allocates a
fresh AST per message per frame, which is exactly that shape. **I have not
proven the link.** Fix 2.1, re-measure the footprint, and you will know. That is
the cheap experiment.

---

## 4. The window

### It is already a real window

`Sources/App/AIChatWindowController.swift:10`, `:609-658`:

```swift
final class AIChatWindow: NSWindow
styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
```

An `NSWindow`, not an `NSPanel`. It resizes, minimises, closes, joins ⌘Tab, goes
full screen, appears in Mission Control, autosaves its frame, and becomes key and
main normally (no `canBecomeKey` override, unlike the launcher's `KeyablePanel`
at `AppDelegate.swift:8-11`).

Your instinct that it is "somehow still anchored" is right, but not for the
reason you would expect. Four separate things produce it.

### One: macOS never adds its own window menu

**This is the answer to "make it occupy half the screen".**

`NSApp.windowsMenu` is **never assigned anywhere in the source**. I grepped
`Sources/` for `windowsMenu`, `servicesMenu` and `helpMenu` and got nothing.
Only `NSApp.mainMenu` is set (`AIChatWindowController.swift:236, :250`), and the
Window submenu is hand-built (`Sources/App/AIChatMenu.swift:54-60`).

Because AppKit does not own that menu, it never injects the standard items. So
the macOS **Move & Resize submenu is absent**: Fill, Left/Right halves, quarters,
Centre, Arrange. Also absent: the window list, Bring All to Front, and Enter
Full Screen as a menu item.

The window itself qualifies for tiling. It is titled, resizable and
`fullScreenPrimary`. The menu path is what is missing.

**Setting `NSApp.windowsMenu` to the Window submenu in `AIChatMenu.makeMenu()`
is a one-line change that gives you native halves, quarters and thirds for
free.** It is the highest-value item in this document per line of code.

> **Correction, same day, from building it.** That one line was not enough,
> because this section named only half the cause. The window had no menu bar
> at all. `SystemAIChatAppShell.present` installed the menu only
> `if NSApp.mainMenu == nil`, and that is never true: the SwiftUI `App`
> lifecycle installs a bar holding the app menu alone at launch. So there was
> no Edit menu, no View menu and no Window menu either, and a `windowsMenu`
> assigned from inside `makeMenu()` did nothing, because AppKit fills a
> Window menu with the system commands only while it is part of the installed
> bar. Reading the source could not show this; looking at the running app
> did. Both faults are fixed in `ce3c090`, and the menu now carries Fill,
> Center, Move & Resize, Full Screen Tile and the window list.

### Two: Quick Launch's own layouts cannot target it

Three separate blockers, which is why this has never worked:

- `closestExternalWindowTarget()` skips any window whose owner pid is Quick
  Launch's own (`Sources/Services/SelectedTextService.swift:66-69`), and
  `rememberIfExternal` does the same (`:86-88`).
- The chat window's `QuickViewModel` is built **without** a `windowManager`
  (`AppDelegate.swift:1705-1729`; the launcher's gets one at `:280`), so any
  `window.*` command run from the chat dies at the guard at
  `QuickViewModel.swift:5574-5581` with "No manageable window was available
  behind Quick Launch."
- The apply path calls `prepareForExternalAction?()` first
  (`QuickViewModel.swift:5585, :5588`), which is wired to `hideWindowForCapture`
  (`AIChatWindowController.swift:445`). Routing own-window layouts through it
  would order the window out before resizing it.

Also: Accessibility is the wrong actuator for an app's own window. The supported
call is `NSWindow.setFrame(_:display:animate:)`.

So the fix is not "let the AX path see our pid". It is a branch before the
guard at `QuickViewModel.swift:5574` that computes the frame from the existing
pure geometry (`Sources/Models/WindowLayout.swift:122-130, :196-261`) and calls
`setFrame` directly, with no `WindowManager`, no AX, and no
`prepareForExternalAction`.

### Three: it re-centres on the launcher's display every open

`AppDelegate.swift:313-316` and `:1686-1690` open the chat with
`showAIChat(on: launcherScreen() ?? screenContainingMouse())`, which sets
`openingScreen`. `place(_:on:)` (`AIChatWindowController.swift:484-488, :663-683`)
then re-centres the window on that display whenever its centre is elsewhere.

**Park the window on one display, open it from another, and it jumps and
re-centres.** A standalone window does not do that. This is probably a large
part of the feeling you are describing.

### Four: the app changes activation policy under you

Covered in 2.7. The Dock icon appears when the chat opens and vanishes when it
closes.

### Also worth knowing

`Keep on Top` sets `window.level = .floating` (`AIChatWindowController.swift:516-519`).
That is the utility-panel band, and Stage Manager, Mission Control grouping and
the system tiling paths treat such windows as auxiliary. **Keep on Top and
first-class native window management are in genuine conflict.** The setting can
stay, but it cannot be on while you expect macOS to tile the window. It is
persisted in UserDefaults (`AIChatWindowModel.swift:84-88, :145`), so check what
it is actually set to before blaming anything else.

It is a singleton: one shared controller, one window (`AppDelegate.swift:159,
:1703-1732`), `tabbingMode = .disallowed` (`:631`). `⌘N` starts a new chat
inside it rather than opening a second window. Two chats side by side is a
bigger change than the rest of this section.

Checked and cleared as non-causes: `hidesOnDeactivate` is not set on the chat
window (the launcher panel sets it, `AppDelegate.swift:674`); Escape only pops
layers and never closes (`AIChatWindowModel.swift:685-710`); there is no
`windowDidResignKey` handler; opening or closing the launcher overlay does not
touch the chat.

### What to change, ranked

1. Set `NSApp.windowsMenu`. Native Move & Resize, the window list and Enter Full
   Screen all arrive for free.
2. Stop repositioning on open: drop `openingScreen`, or honour it only on the
   first open per launch.
3. Own-window layouts: the `setFrame` branch described above.
4. Stop flipping activation policy on every close. Stay `.regular` once the
   chat has been opened this session. Costs a permanent Dock icon, buys back a
   second per open. Visible behaviour change, so your call.
5. Leave Keep on Top off if you want native tiling.

---

## 5. Slash commands

### What exists

Two. `/new` and `/clear` (`QuickViewModel+ChatCommands.swift:54-78`,
`Sources/Services/Chat/QuickChatCommands.swift:36-40`). Case-insensitive, and a
saved-prompt alias can never shadow them (`ChatCommand.swift:106-111`).

`knownChatCommands` is literally `[]` (`QuickViewModel+ChatCommands.swift:18`).
The router is built to take RTI-style `/meeting` names but Quick Launch
registers none.

Anything else starting with `/` is refused locally, with "Send as Text" as the
only way through (`ChatPreSendControls.swift:110-147`). Repeated Return and
⌘Return stay local; only the explicit button sends (`:83-89`).

### The placeholder promises a feature that does not exist

`QuickViewModel.swift:2920`:

```swift
static let quickAIPlaceholder = "Ask anything, @ to attach, or / for commands…"
```

Typing `/` opens nothing. The `@` half works: `addContextTriggerDidChange`
(`QuickViewModel.swift:4949-4973`) opens the Add Context menu, wired at
`QuickAIComposer.swift:169-176`. There is no `/` equivalent.

Grepping `Sources/` for `/new` or `/clear` returns one code comment. The two
commands appear in **no UI string, no ⌘K row, no Settings pane, no help text.**
The only place they are named is the error you get for typing something else.

### Everything a `/` palette needs already exists

- The prefix is already `/` (`Sources/Models/QuickSettings.swift:167`).
- Saved prompts already key off it: `/translate`, `/zh`, `/grammar`, `/improve`,
  `/shorter`, `/bullets`, `/tldr` (`Sources/Models/SavedPrompt.swift:252`).
- A fuzzy autocomplete engine already exists and works:
  `SavedPromptResolver.matches` (`SavedPromptResolver.swift:102-133`), exposed as
  `savedPromptMatches` (`QuickViewModel.swift:1083-1090`). **It is drawn in
  exactly one place**, `Sources/Views/OverlayView.swift:241-263`, inside the
  launcher root search, which never renders on a chat surface
  (`OverlayView.swift:19-27`). `QuickAIComposer.swift` never references it.
- `SkillLibrary` reads `~/.claude/skills` in one readdir
  (`Sources/Services/SkillLibrary.swift:22-28`). **32 skills on this Mac.**
  Injected into both view models (`AppDelegate.swift:305, :1727`). Today they are
  reachable only as a model tool (`read_skill`, `ChatToolbox.swift:125-135`),
  never as something you can type.
- `QuickAIFloatingChooser` (`Sources/Views/QuickAIFloatingChooser.swift:15`)
  already renders four chooser panes in the slot directly above the composer,
  each with its own search, arrows and Return.

So a `/` palette is a fifth pane in an existing slot, fed by three catalogs that
are already loaded, triggered by a mirror of `addContextTriggerDidChange`. The
pieces are all built. Nobody connected them.

One gap to close while there: the AI Chat window's view model is built **without**
`houseCommandCatalog` (`AppDelegate.swift:1713-1725`; the launcher's gets one at
`:296`), so every house-command path returns at its `guard let` and house
commands are unreachable from AI Chat entirely.

---

## 6. Keyboard

### The sidebar hotkey already exists

`Sources/Models/ShortcutAction.swift:203` and `AIChatWindowModel.swift:34`:

```swift
nonisolated static let chatListShortcut: KeyShortcut = .controlCommand("s")
```

**⌃⌘S** toggles the chat list. **⌘P** also toggles it, and if the rail is open
but unfocused, `⌘P` moves focus into it instead (`AIChatWindowModel.swift:784-791`).
There is a View menu item (`AIChatMenu.swift:52`), a ⌘K row
(`QuickAISurfaceAction.swift:95, :106`), and the header button's tooltip names
the key (`AIChatWindowView.swift:105`).

So this is a discovery failure, not a missing feature. Which is its own finding:
you use this daily and did not know its sidebar key.

Two things make it undiscoverable. The Settings row is titled "Recent Chats"
with the detail "Past chats in place of the thread", which describes the Quick AI
behaviour, not the window's. And four doc comments still name the retired `⌘\`
(`AIChatWindowView.swift:9`, `AIChatWindowModel.swift:92-93`,
`QuickAISurfaceAction.swift:15, :17`).

### The real gaps

- **The thread cannot take keyboard focus at all.** `QuickAIThread.swift` has no
  `onKeyPress`, no `@FocusState`, no `contextMenu`, no `accessibilityAction`. It
  is scroll-only.
- **You cannot focus an individual answer**, and therefore cannot copy one
  directly. `⇧⌘C` copies only the current answer; any other message needs
  ⌘K → "Copy Message…" → arrows → Return (`QuickViewModel.swift:6291, :6307-6308`).
- **No key returns focus from the sidebar to the composer while keeping the rail
  open.** Escape at `focus == .rail` hides the rail
  (`AIChatWindowModel.swift:702-704`); `⌘P` from the rail falls through to
  `toggleRail()` → `hideRail()` → `focusComposer()`. The only way back that keeps
  the rail open is Return on a chat row (`:333-341`).
- **Arrowing through sidebar chats works only while the rail's search field holds
  focus** (`AIChatWindowView.swift:339`). There is no separate list focus state.
- **Thread scrolling works only when the composer draft is empty.** With text in
  it, the text view takes `⌘↑ ⌘↓ ⌥↑ ⌥↓` PageUp PageDown
  (`AIChatWindowController.swift:82-91`, `ComposerCaretMove.composerKeepsKeys:127-140`).
- House commands unreachable from AI Chat (no catalog injected, see section 5).

### What does work

⌘N new chat · ⌘P recent chats / focus rail · ⌘[ ⌘] previous/next chat · ⌘E
rename · ⇧⌘P pin · ⌃X delete (armed) · ⌘J open in AI Chat · ⇧⌘O change model ·
⌥⌘A assistant · ⌥⌘K tools · ⌥⌘C copy chat · ⌥⌘P continue in pi · ⌥⌘M capture to
memory · ⌘O open source · ⌃⌘S chat list · ⌘F find · ⌘G ⇧⌘G next/previous match ·
⌘1…⌘9 jump to rail row · ⇧Tab into the attachment chip strip, then ← → space ⌫ ·
↑ on an empty composer recalls the last question · Escape unwinds one layer at a
time (`AIChatWindowModel.swift:685-712`).

Answer keys: ⌥⌘V replace selection · ⌘↩ paste into previous app · ⇧⌘C copy
answer · ⌘L read aloud · ⇧⌘N save as snippet · ⇧⌘W search web · ⌘R ⇧⌘R
regenerate · ⌥⌘T transform · ⇧⌘M fold newest question.

The full table is `Sources/Models/ShortcutAction.swift:23-219`, all rebindable
from Settings → Keyboard Shortcuts.

---

## 7. What I would do, in order

1. **Set `NSApp.windowsMenu`** (4, one). One line, and native halves, quarters
   and thirds arrive immediately. Cheapest win in the document, and it is the
   literal answer to "let me put it on half the screen".
2. **Fix the three markdown caches** (2.1). Biggest latency win, and it may also
   explain the memory footprint. Re-measure the footprint after.
3. **Stop awaiting the archive checkpoint in the token loop** (2.2). The other
   half of the streaming lag. Ships with item 2, same symptom.
4. **Delete the scope pill** (1). Removes a control that can only hurt you,
   removes a label that lies about its own state, and removes nine policy
   evaluations per keystroke. Amend `docs/chat-harmonization-plan-20260917.md`
   and `CLAUDE.md:85-89` in the same change.
5. **Make the destination line warning-only** (1). Keeps the five messages that
   matter, loses the one you see every time. Same change as item 4.
6. **Stop re-centring the window on open** (4, three).
7. **Add the `/` palette** (5). Fifth chooser pane, three catalogs already
   loaded, and it makes the placeholder honest.
8. **Own-window layout commands** (4, two), via `setFrame`, not AX, not
   `WindowManager`, and not through `prepareForExternalAction`.
9. **Surface `⌃⌘S`** (6). Fix the four doc comments still naming the retired
   `⌘\`, and retitle the Settings row so it describes the window's behaviour.
10. **Stop flipping activation policy on every close** (2.7). Visible change,
    your call.
11. **Bound `AppIconCache` and `ScreenshotTextIndex`** (3). Neither has any
    eviction at all today.
12. **A hands-on keyboard pass** for the gaps in section 6, especially the
    thread having no focus state.

Item 1 is a line. Items 2 and 3 are one sitting. Items 4 and 5 are one change to
two files. Everything above item 6 is small.

---

## What I did not verify

- That the markdown churn is what holds the 164 MB reclaimable (3). Fix 2.1 and
  re-measure; that settles it.
- Whether the clipboard poll invalidates the chat body (2.9).
- Whether SwiftUI actually re-enters `MarkdownTextView.body` on every pass. The
  fresh `instanceID` String and the closure parameters make a skip unlikely, and
  the authors' own comment at `MarkdownRenderer.swift:148-151` says they
  measured re-evaluation on every state change, but SwiftUI's internal field
  comparison is not readable from source.
- Anything by running the app. This is source reading plus measurements of the
  running process and the data directory. No profiler trace, no Instruments run.
  One Instruments time profile while streaming a long answer into a long thread
  would confirm or refute 2.1 and 2.2 in about five minutes, and that is the
  right next step if you want proof before touching anything.
