# Screen context as an agent capability

Status: proposal, 2026-08-25. Nothing here is built yet.

This answers one question: how does a database of past on-screen activity
become something an agent calls, trusts, and acts on.

---

## 1. Measured starting position

Everything below was measured on this machine on 2026-08-25, not estimated.

| Fact | Value |
|---|---|
| Quick Launch store | 929 MB SQLite, 41,266 frames, all `source = coast` |
| Legacy media | 831 MB, 2,705 files |
| Original Coast store still on disk | 2.7 GB (`~/Library/Application Support/inc.attention.rem/`) |
| Real capture span | 2026-08-07 to 2026-08-12, 6 days |
| Cost per day | ~290 MB, so ~106 GB per year |
| Owned capture | hard-locked off (`ScreenHistoryReleasePolicy.allowsOwnedCapture = false`) |
| Times searched | zero, per `launcher-usage.json` |

The archive is duplicated. Quick Launch imported Coast, and both copies remain.
The import also dropped Coast's accessibility trees, which the original still
holds: 50,425 AX snapshots and 1.8 million AX nodes.

### The number that drives the design

Deduplicating OCR boxes per application, first occurrence wins:

```
boxes total     6,455,874   163 MB of text
boxes unique      338,571   11.4 MB of text   (5.2%)
reduction            14.3x
```

Six days of screen text compresses to 11.4 MB. That is about 2 MB per day, or
roughly 700 MB per year, fully searchable, small enough to hand an LLM whole.
The same six days cost 1.7 GB as pixels.

**Text is the cheap permanent layer. Pixels are the expensive perishable
layer.** Every decision below follows from that split.

---

## 2. Gathering: accessibility or OCR, per application

These are not competing designs. They fail in different places, so the router
picks per app. Live probe of the accessibility tree, 2026-08-25:

| App | AX text | Verdict |
|---|---|---|
| Claude | 7,909 chars | AX is enough |
| Slack | 4,114 chars | AX is enough |
| Finder | 2,130 chars | AX is enough |
| Ghostty | 169 chars | pixels only |
| WeChat | 6 chars | pixels only |

WeChat is confirmed twice. The live probe returns 1 window and 6 characters.
Coast's historical WeChat "complete_tree" snapshots hold 5 nodes and 520 bytes,
against 879 nodes and 227 KB for a Claude snapshot. WeChat Mac now runs on
WeChatAppEx and exposes nothing to accessibility. It never did.

**Routing rule.** Read the AX tree every tick. It is cheap, the text is clean,
and it carries two things OCR cannot produce: the page URL and the window's
backing document path. When a window returns under a threshold of text, fall
back to a screenshot plus OCR for that window only. Maintain the blackout list
from measurement, not assumption, and re-measure after app updates.

This makes pixels the exception. On the app mix in the current archive, AX
would cover roughly 80% of frames, and WeChat plus terminals would account for
nearly all of the fallback.

---

## 3. Arranging: four layers, not one table

1. **Moment.** One capture tick. Time, app, bundle id, window title, URL,
   document path, source (`ax` or `ocr`), text.
2. **Block.** Consecutive moments in the same app and window, merged. A block
   under a dwell threshold is transit and gets no entry. This is the timeline
   the agent reads first.
3. **Line index.** Every distinct text line, keyed by app, with first and last
   seen time and the blocks it appeared in. This is the 14.3x layer and the
   thing that makes long-range recall affordable.
4. **Pixels.** A screenshot per moment, kept for a short retention window only.

Retention differs by layer. Pixels expire in weeks. Blocks and the line index
never expire, because they cost about 2 MB a day.

---

## 4. The tool surface

Four calls. This shape is not invented here; the retired Coast CLI proved it,
and the existing `search_web` function tool in
`Sources/Services/OpenAICompatibleService.swift` is the local pattern to copy.

```
context_timeline(range, min_dwell_secs?)
  -> blocks: [{ id, start, end, app, title, url?, document?, summary }]
  Answers "what was I doing on Tuesday". Cheap. The agent's first call.

context_search(query, range?, app?, limit?)
  -> hits: [{ block_id, moment_id, time, app, title, url?, document?, excerpt }]
  FTS over the line index. Answers "find the thing about X".

context_moment(id, include: [text | image | neighbors])
  -> full text, the surrounding block, and the screenshot when asked
  The zoom-in. `image` is the only call that costs pixels or vision tokens.

context_apps(range)
  -> [{ app, blocks, minutes, ax_coverage }]
  Orientation and blackout diagnostics.
```

Design rules that matter more than the signatures:

- **Every result carries a pointer.** A URL or a document path, never only
  scraped text. The agent opens the real artifact rather than trusting a
  fragment. This is the single biggest quality lever, and it is also the thing
  OCR cannot give you, which is another reason to prefer AX where it works.
- **Cheap before expensive.** Timeline and search return text. Images require
  a second, explicit call.
- **Every result says `ax` or `ocr`.** The agent should trust an OCR excerpt
  less, and should say so when it answers.

### Delivery: one core, two consumers

Build the query core once in Swift, then expose it twice:

1. **`quickctx` CLI** plus a skill file, for Claude Code, Codex, and anything
   else with a shell. This is how the Coast CLI worked and why it was usable.
   It is also the faster of the two to build and the easier to evaluate.
2. **A function tool in Quick Launch's own model loop**, registered beside
   `search_web`, so the overlay can answer "what was I looking at" in place.

Start with the CLI. It is testable from a terminal, it serves the agent you
actually use for context work, and the in-app tool is a thin wrapper over the
same core afterwards.

---

## 5. What the agent may do next

Read is free. Anything that touches the world is confirmed first.

| Action | Gate |
|---|---|
| Open the document path or URL from a result | ask once |
| Copy an excerpt to the clipboard | free |
| Save a reconstructed summary to the vault | ask once |
| Draft an email or message from what it found | draft only, never send |
| Delete or prune history | explicit, never automatic |

The failure mode to design against is not a wrong answer. It is an agent that
reads a stale frame, treats it as current, and acts. Two defences: every result
carries its capture time and the agent must state it, and content visible in a
frame is evidence of what was on screen, never evidence of what is true now.

---

## 6. Evaluation

### What exists

`Tests/ScreenHistoryProductEvaluationTests.swift` already runs a receipt-based
suite: retrieval rank (`SH-R01` to `SH-R03`), surrounding sequence (`SH-S`),
parsed filters (`SH-F`), exclusion and routing boundaries (`SH-E`), migration
reconciliation (`SH-M`), and latency at 50,000 records (`SH-P01`). The security
suite proves no network or process calls on the retrieval path.

That is a real harness. Its weakness is size: three retrieval cases decide
whether search works.

### What is missing

1. **A labelled question set over the frozen archive.** The Coast data is
   immutable now, which makes it a perfect fixture. Write 40 to 60 real
   questions with known answers, in the shapes you actually ask: "what was I
   doing at 14:00 on the 11th", "which app did I see X in", "find the doc about
   Y". Score recall@5 and whether the returned moment actually contains the
   answer.
2. **An AX-versus-OCR bake-off per app.** Same window, both methods, compare
   extracted text against ground truth. This produces the blackout list as
   evidence and needs re-running after app updates.
3. **A cost budget per question.** Tokens and wall time for a typical lookup.
   A capability that costs 40,000 tokens to answer "what was I doing" will not
   get used.
4. **A staleness test.** Feed the agent a frame containing an out-of-date fact
   and check that it reports the capture time rather than asserting it.

---

## 7. Decisions needed

1. **Reclaim 2.7 GB or keep it?** The original Coast store is a duplicate of
   the imported data, plus the AX trees the import dropped. Either extract the
   AX text into the new line index and then delete it, or delete it now and
   accept OCR-only history for 2026-08-07 to 08-12.
2. **Turn capture back on, and under which design?** Owned capture is
   hard-locked off. Re-enabling it as AX-first with OCR fallback is a different
   product from the pixel recorder that is currently in the code, and it needs
   its own consent design.
3. **CLI first, or in-app tool first?** The recommendation above is CLI first.
4. **Prune the pixel layer now?** Dropping `ocr_box` and the media files takes
   the current store from 1.7 GB to roughly 380 MB and keeps text search
   working, at the cost of image previews and highlight boxes.
