# Chat context and composer review — 2026-09-15

## Scope and coverage

Full review of the Quick AI and AI Chat path from attaching or selecting
material to composing, sending, moving the draft, and regenerating an answer.
Includes empty, reading, ready, failed, long-text, and minimum-window states.
Provider account setup, global macOS hotkeys, and device-to-device clipboard
transfer are outside this review.

The implementation uses SwiftUI, native AppKit editing and drag providers,
and the existing House tokens. Conventions: `CLAUDE.md`,
`../design-system/DESIGN.md`, `../design-system/SWIFT.md`, and the shared
component registry. No token values or attachment persistence rules changed.

| Domain | Evidence inspected | Result |
| --- | --- | --- |
| Accessibility | Native editing keys, action semantics, chip Retry/Remove, preview shortcut, accessible names | Keyboard and action fixes; live VoiceOver narration not tested |
| Layout | Native renders at Quick AI's standard size and AI Chat's minimum size; growing fields and floating panes | Multiline fields and constrained panes verified at both minimum sizes |
| Writing | Attach menu, readiness, failure messages, pending routing, search choices | Files and links first; status describes what happens on Send |
| Typography | English, Chinese, multiline code, and long unbroken strings | Bounded wrapping and scrolling; full selected text can be inspected |
| Colors | Light/dark renders and sampled attachment status text | Readiness and failure text measure 14.74:1 in light and 11.86:1 in dark fixtures |
| UI | Shared composer, preview popover, action button, provider submenu | Existing House controls and motion retained |

## Findings

Locations identify the implementation and the corresponding regression seam.

| Severity | Domain | Location | Before | After | Why |
| --- | --- | --- | --- | --- | --- |
| HIGH | Accessibility | `Sources/Views/QuickAIComposer.swift:15`; `Tests/LongComposerTests.swift` | Quick AI forced drafts into one horizontal line; Shift-Return and caret keys ran chat actions | Four visible lines in Quick AI, eight in AI Chat, then native scrolling; newline, caret and IME behavior preserved | Long drafts must remain editable |
| HIGH | Layout | `Sources/Views/QuickAIFloatingChooser.swift:6` | Panes assumed a one-line composer | Panes use the composer's measured size | Attach and command controls must remain reachable |
| HIGH | Accessibility | `Sources/ViewModels/QuickViewModel+AIChat.swift:193`; `Tests/AttachmentUsabilityTests.swift` | Expansion omitted the launch-time selection | The draft carries its selection snapshot | The next request must contain the context shown before expansion |
| HIGH | Writing | `Sources/ViewModels/QuickViewModel+Attachments.swift:120`; `Tests/AttachmentUsabilityTests.swift` | Failed files disappeared while an incomplete question sent | A new send waits for reads and requires Retry or Remove for failures | A successful send must not imply a failed file was read |
| HIGH | Accessibility | `Sources/ViewModels/AttachmentTray.swift:652`; `Tests/AttachmentDropContinuityTests.swift` | A drop had no chip until provider resolution; Send or expansion could discard it | Reading chips appear immediately and their tasks transfer with the draft | Rapid drag-and-send must retain the dropped files |
| HIGH | Writing | `Sources/ViewModels/QuickViewModel.swift:7065`; `Tests/AttachmentUsabilityTests.swift` | Regenerate could consume new draft context or be blocked by its failed files | Regenerate uses the original turn and retains the entire new draft | Two different questions must not share unintended context |
| HIGH | Writing | `Sources/Services/AttachmentRequestComposer.swift:53`; `Tests/AttachmentImageLifecycleTests.swift` | Prior images could silently disappear when vision became unavailable | Available pixels become local OCR; missing images are identified in the request | The model must not answer as though it saw an absent image |
| HIGH | Writing | `Sources/Services/ScreenAwarenessService.swift:48` | Explicit selection shared a silent 6,000-character ambient-context cutoff | Ambient context remains capped; selected text reaches the normal request budget | Preview and request contents must agree |
| HIGH | Colors | `Sources/Views/AttachmentChip.swift`; `Tests/AttachmentUsabilityRenderProofTests.swift` | Important status text measured below 4.5:1 in the light fixture | Readiness, failure, routing, and preview text use stronger existing ink | These lines determine whether the requested context is available |
| MEDIUM | Typography | `Sources/Views/SelectedTextPreview.swift:5` | The selected-text chip exposed only a short excerpt | Preview and `⌥⌘I` expose the full, selectable passage | Users can check the material before sending |
| MEDIUM | Accessibility | `Sources/Views/QuickAIComposer.swift:15` | The primary action was a text hint | It is a button whose behavior matches Ask, Stop, or Copy | Mouse and keyboard actions should agree |
| MEDIUM | Writing | `Sources/Models/WebSearchProvider.swift`; `Tests/WebSearchProviderTests.swift` | The app hardcoded mixed search results | Automatic, Google, and Bing share one saved setting across chat and tools | Users can choose the search source without managing transport details |
| MEDIUM | UI | `Sources/Services/Attachments/AttachmentSessionStore.swift:153` | Deleting an OCR-only image could leave its text in memory | Text and pixels release independently when the last reference is deleted | Session cleanup must cover both representations |

## Considered but rejected

| Candidate | Reason |
| --- | --- |
| Turn every large paste into a file attachment | Literal pasted text should remain editable; a silent conversion would add another hidden behavior |
| Add persistent attachment text storage | The app's established contract keeps this content in session memory |
| Offer DuckDuckGo alongside Google and Bing | Its live endpoint returned a CAPTCHA and no results during this review |
| Expose SSH/HTTP transport choices in the main chat flow | Existing transport supports the requested provider choices; infrastructure controls would obscure the user-facing choice |

## Verification

- Baseline: `swift test --filter 'AttachmentUsabilityTests|LongComposerTests'`
  reproduced 11 issues across six tests in 0.088 seconds.
- Integrated targeted run: 238 tests across 15 suites passed. Includes gated
  native drag callbacks, request assembly, selection handoff, retries, image
  fallback, long-draft geometry and search-provider routing.
- `make test` in `design-system`: 65 tests passed, including registry and
  generated-file consistency.
- Native render artifacts: `/tmp/quick-launch-render-proof/`, including
  `composer-*`, `att-selection-*`, `att-usability-*`, and
  `web-search-provider-*`, in both appearances.
- Final `swift test`: 2,122 tests across 183 suites passed.
- `QUICK_LAUNCH_NATIVE_FOCUS_PROOF=1 swift test --skip-build --filter PaletteRailFocusProofTests`: the isolated native focus check passed.
- Long drafts plus selected text, a file, and the Attach or Actions pane fit
  at both minimum sizes. Explicit thread navigation uses immediate
  transactions; the three existing native scrolling tests pass.
- Rendered readiness/failure ink: light foreground (25,24,23) on
  (234,234,234), 14.74:1; dark foreground (230,229,224) on (38,39,40),
  11.86:1. These are fixture samples, not a whole-app conformance claim.
- `../design-system/bin/design-lint --strict .` and `git diff --check` pass.
- Not verified: this revision running as the installed app. Signed deployment
  is waiting on access to the existing macOS signing key.

## Verdict

Approve
