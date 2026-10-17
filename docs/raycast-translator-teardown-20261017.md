# Raycast Translator teardown vs Quick Launch Translator (2026-10-17)

Target: `/Applications/Raycast.app` v2.8.0.0. Static read only (REA JS graph + direct reads of the shipped bundles). Raycast was not run; no network capture.

REA evidence: `analyze_javascript_application` on the frontend bundle, parent `ev_474633b60717a4fc0520f9cdd4c51780ff8a185d133e34fcf108d842a08f7eb2` (coverage partial, 5 selected modules).

## How Raycast's Translator works

### Architecture
- Raycast 2.x is three layers: Swift shell (`Contents/MacOS/Raycast`), a React frontend (`.../Resources/frontend/*.js`), and a Node backend (`.../Resources/backend/index.mjs`). Translate lives in JS, not in Swift.
- Frontend calls `ipc.backend.translator.translate({text, source, target})` with a 10 s IPC timeout (`register-query-client-*.js`).

### Engine (backend/index.mjs)
- `POST https://backend.raycast.com/api/v1/translations`, `Authorization: Bearer <Raycast account token>`.
- Body: `{format: "text", q, source?, target}`. Response: `data.translations[].translatedText / detectedSourceLanguage`.
- That is exactly the Google Cloud Translation v2 shape. Inference: Raycast proxies Google Translate (NMT), not an LLM. One shot, no streaming.
- Source `auto` is sent as no source; Google detects it and returns the detected code.
- One AbortController per scope (`ipc`, `rootSearch`): a new request aborts the previous one in that scope.
- Pro feature (`proFeature: "translator"`); no token = "Authorization is required for translation".

### Translator window (main-window-*.js)
- Live translate with a 330 ms debounce. A `requestSeq` counter drops stale replies.
- Same-language short-circuit: if source is not `auto` and source == target, it echoes the text with no request.
- Source and target pickers each keep their own remembered value (synced settings `defaultSourceLanguage`, `defaultTargetLanguage`, plus last-used).
- Recent text: `translator::recent-text` is saved on close and restored on reopen within the "pop to root" timeout.
- Swap reuses the finished translation as the new source when it matches the current pair.
- Speak button (⌘L) reads the translation aloud with the system voice; offers to install a voice pack.
- Settings: Primary Action (default `copy`), Use Selected Text as Source (default OFF), default source and target.
- About 130 languages (Google list), shown with the detected source label above the text.

### Inline translate in root search
- Regex on the root search text: `^(.*)\s+(?:in|into)\s+([^\s]+)$`. Quotes around the phrase are stripped.
- The language word is transliterated, lowercased, letters only; needs 3+ chars; prefix-matched against language names (exact match first, then shortest).
- So `good morning in jap` gives a row "Translate to Japanese" with the live result, 150 ms debounce, cached per (target, phrase). Return copies the translation; a second action copies the source.

### Custom translate commands
- User-saved presets: name, source, target, output behaviour `open-in-raycast` or `replace-selection`. Each gets its own alias and hotkey.
- `replace-selection`: closes the window, reads the selection, translates, writes it back in place, with a HUD ("Translating…", "Translated", "Failed translating"). No window shown.

## Quick Launch today (Sources/ViewModels/TranslatorModel.swift)
- LLM engine through the chosen model, streamed, with a tone and format preserving prompt. 600 ms debounce. Task cancel drops stale replies.
- On-device source detection (NLLanguageRecognizer + CJK ratio), CJK-to-English direction rule, pinyin for Chinese, swap round-trip, copy (⌘↩), paste back (⇧⌘↩), copy-when-ready, clipboard as source, 500-item history, 21 languages.
- Launcher: ⇧↩ translate typed text (EN/ZH by script), `/translate` and `/zh` saved prompts, Translate chip opens the window with the selection.

## Gap list (Raycast has, Quick Launch lacks), ranked by value

Built on branch `translator-raycast-parity`: gap 1, plus a chosen source language with Swap in the window.
1. Inline `<text> in <language>` row in the launcher with the live result. Biggest daily-use gap. Port the regex and prefix match; reuse TranslatorModel's request path.
2. Replace-selection translate presets: hotkey, translate the selection in place, HUD, no window. Already covered: a saved action with a hotkey and the "Replace selected text" output does this (for example `zh` or `translate` with a hotkey set). No code needed.
3. Restore the last source text on reopen within a short timeout (Quick Launch clears on every `prepare`).
4. Speak translation via local-tts (already wired for Read Aloud).
5. Debounce 600 to about 350 ms, and skip the model call when source == target.
6. Longer language list (low value for Tristan's EN/ZH use).

## Not worth copying
- Google NMT engine. It is faster, but the LLM gives better tone and register, which is the point for research work. An optional fast path is Apple's on-device Translation framework (macOS 15+); judge that separately, it is not what Raycast uses.
- Selection prefill default OFF. Quick Launch's auto-prefill fits how Tristan works.

## Unknowns
- Server side of `/api/v1/translations` is not visible; "Google v2" is an inference from the request and response shape.
- No runtime capture was done, so latency and real responses are not observed.
