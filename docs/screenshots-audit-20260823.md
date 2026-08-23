# Screenshots feature audit, 2026-08-23

**Status: fixes applied the same day.** Search plural tolerance, date words
anywhere, 400-item cap, background scan with a real root badge, shared name
prefixes, live OCR ranking, thumbnail memory budget, verified paste, and
Finder file selection in Screen Awareness all shipped; see the Unreleased
section of CHANGELOG.md. Item 4 (saving Quick Launch's own captures to disk)
was deliberately left out: it touches the product's privacy posture and needs
its own decision.

Verified against the running app (1.1.0, built from bfcdb72 at 12:59 today)
and Tristan's real Desktop by executing the actual `QuickViewModel` against
`~/Desktop`. All 560 tests pass; no code was changed.

## Answers first

**Why "screenshots" didn't show the shot from a moment ago.**
The file exists and the catalog finds it. Reproduced with his real data:

- Entering Screenshots with an empty query works. Today's
  `Screenshot 2026-08-23 at 13.02.12.png` shows as row 3 (after the two
  capture commands), labelled "Aug 23, 13:02:12 · Today".
- Typing `screenshots` **inside** the catalog returns **zero rows**, not even
  the capture commands. This is the likely path he hit.
- At root, before entering, the row badge reads "Screenshots (2)". The count
  is only the two capture commands because files load on entry. Misleading.

Root cause of the zero-result search: rows are matched on the reformatted
title ("Aug 23, 13:02:12") and the filename stem keywords. The fuzzy matcher
is subsequence based, so the trailing "s" in "screenshots" must appear after
"screenshot" but the digit wall ("20260823at…") blocks it. Singular
"screenshot" matches all 240 files; plural matches none. No stemming, and the
OCR fallback needs the literal word inside the image.

Second way a fresh capture can be invisible: screenshots taken through Quick
Launch itself (⌘⇧S window, ⌘⇧D display, Send Screen Area to AI) are memory-only
attachments. Nothing is written to disk, so they can never appear in the
catalog or the OCR index.

## Bugs and UX issues found

1. In-catalog search for plural or re-worded queries returns nothing
   (repro'd). Titles hide the filename words people would type.
2. Root badge shows "Screenshots (2)" until entered; files not counted.
3. Prefix-list drift: `LatestScreenshotFinder.newestScreenshot` accepts only
   names starting "screenshot", while the catalog also lists "screen shot",
   "cleanshot", "scr-". A CleanShot capture appears in the catalog but
   Attach/Paste Latest Screenshot cannot find it (Sources/Services/
   LatestScreenshotFinder.swift:35 vs ScreenshotLibrary.swift:9).
4. Cap: the catalog lists and OCR-indexes only the 240 newest files. His
   Desktop has 1,090 matching images; ~850 are unreachable and unsearchable.
5. Single folder: only `com.apple.screencapture location`, else Desktop.
   Shots saved anywhere else never show.
6. Date words must lead the query: "today acme" filters, "acme today" does
   not parse the date part at all.
7. Stale OCR results within a session: while background indexing lands new
   text matches, the launcher match cache key does not change, so text hits
   appear only after the next keystroke.
8. Own captures leave no trace (see above). If he expects "my screenshots"
   to include Quick Launch captures, it never will without a save policy.

## Is select-area OCR to clipboard implemented? Yes.

Command "Copy Text from Screen Area" (`ocr.area`). Flow: system selection UI
(`/usr/sbin/screencapture -i -x`) → Vision OCR on this Mac → text copied to
the clipboard and shown in the panel. Sources/ViewModels/QuickViewModel.swift:2131,
Sources/Services/ScreenAwarenessService.swift:117. No model involved.

Global hotkey: any item can carry one. Set it once in Settings › Items (or
⌘K on the row › Hotkey); it registers system-wide via RegisterEventHotKey
(Sources/App/AppDelegate.swift:713) and runs the capture directly. No default
hotkey ships, so out of the box it is launcher-only. Related: "Send Screen
Area to AI" runs the same selection then asks the vision model.

## Is full OCR search over all screenshots implemented? Yes.

`ScreenshotTextIndex`: Apple Vision, on-device, accurate level, language
correction, en + zh-Hans + zh-Hant. Results cached in
`~/Library/Application Support/Quick Launch/screenshot-text-index.json`
(his currently holds 240 entries). Refresh runs when the catalog opens;
new files index in the background. Querying matches words that exist only
inside images and marks those rows "Text match ·".

Limits: covers the same single folder and the same 240 newest files; matching
is literal substring / all-words containment, so plurals or paraphrases miss.

## Suggested fixes, ranked

1. Make in-catalog search forgiving: fold filename stems into titles or add
   stemming/prefix tolerance so "screenshots" matches everything and empty
   states stop looking like broken states.
2. Load the file list eagerly enough that the root badge shows the real count.
3. Share one prefix list between the library and latest-screenshot finder.
4. Decide whether Quick Launch captures should optionally land in the
   screenshots folder (product decision, touches the privacy posture).
5. Raise or make configurable the 240-item cap; consider indexing more than
   is listed.
6. Accept date words anywhere in the query, not just first.
