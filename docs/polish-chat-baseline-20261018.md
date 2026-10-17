# AI Chat performance baseline (unit B0)

Taken before any AI Chat polish change, so later units can show a before and after with the same method. No behaviour changed.

Base commit: 84efcc7986ffe0afb1cb0a8219fc86de3ae27bc6. Machine: Apple M5, arm64, macOS 26, debug build (`swift test`), quiet machine, three runs.

## Method

`Tests/ChatPerformanceBaselineTests.swift`, opt-in (`QUICK_LAUNCH_PERF=1`), asserts no time budget, prints `PERF` lines:

    QUICK_LAUNCH_PERF=1 swift test --filter ChatPerformanceBaselineTests 2>&1 | grep '^PERF'

Clock: `ContinuousClock`, main actor. Debug numbers run slower than release; compare debug to debug only.

Sample answer: 6,000 characters of mixed markdown (bold, inline code, a list, a fenced code block), grown in 150 flushes of 40 characters. Caches are not cleared between flushes, which is how a live answer behaves (the streaming run is `transient`).

## Numbers (per flush, 150 flushes)

| Path | Mean | Median | p95 | Max |
|---|---|---|---|---|
| Render path only: `cachedSegments` + `proseHeight` per prose run | 1.9 to 2.1 ms | 1.9 ms | 2.6 to 4.0 ms | 17 to 22 ms |
| Hosted view: `MarkdownTextView` rootView swap + `layoutSubtreeIfNeeded` (text storage replace, measure, layout) | 2.2 to 2.6 ms | 2.0 to 2.1 ms | 4.6 to 5.7 ms | 14 to 18 ms |

One run showed a noisy 3.3 / 3.9 ms mean while another build was active; the other two are the quiet figures.

Reading: a flush costs about 2 ms at an average length of 3,000 characters, and the cost is dominated by re-parsing and re-rendering the whole growing run each flush (work grows with length). The max (the first flush after the 64-entry caches fill, or a code-block boundary) is 7 to 10 times the median.

## 60-answer chat (120 messages, 99,400 characters)

| Step | Time |
|---|---|
| `loadConversation` | 0.08 ms |
| First layout of `QuickAIThread` in the chat window frame | 16 ms (only 2 prose text views materialized: the thread is lazy) |
| Relayout, nothing changed | 0.012 ms |
| Measure all 60 answers cold (`MarkdownRenderer.measuredHeight`) | 65 to 68 ms |
| Host all 60 answers in one non-lazy stack and lay out | 660 to 775 ms (measurements above are already cached) |

Reading: opening a long chat is cheap because the thread is lazy. The cost shows when the whole chat is forced to lay out (scroll to top, Find in Chat across all answers, a window resize that invalidates every width-keyed measurement). The 64-entry caches (`MarkdownCache` limit) are smaller than a 60-answer chat's segment count, so a long chat re-measures as it scrolls.

## Not measured

- Frame time and hitches on screen (no display link in tests).
- Release-build numbers.
- Real network chunk sizes; 40 characters is a fixed stand-in.

## After B1: streaming re-renders only the tail

Same machine, method and sample (6,000 characters, 150 flushes of 40), debug build, three quiet runs. The flush path is now `StreamingAnswer` (split and render the tail, freeze finished blocks) plus the live run's own incremental layout measure; the text view replaces only the tail's characters.

| Path | Before (mean / median / max) | After (mean / median / max) |
|---|---|---|
| Render path: split, render, measure (new test `streamingFlushIncrementalCost`; before = `streamingFlushRenderCost`, still the whole-answer path) | 1.8 to 2.0 / 1.8 to 2.0 / 17 to 31 ms | 0.12 to 0.13 / 0.11 / 0.85 ms |
| Hosted view: rootView swap + `layoutSubtreeIfNeeded` | 2.2 to 2.6 / 2.0 to 2.1 / 14 to 18 ms | 1.4 to 1.5 / 1.0 / 14 to 15 ms |

Reading: the work of a flush no longer grows with the answer (about 16 times cheaper on the render path). The hosted figure also holds SwiftUI and TextKit 2 layout of the whole text view, which this unit does not touch; its max (14 ms) is the first flush that builds the views. The 60-answer numbers are unchanged (finished answers do not stream).
