# Current Quick Launch map

Read-only scout result,2026-10-21. Source evidence only unless stated. No tests or native UI were run by this scout. Existing test files locate coverage. Their passing status requires a separate run.

## Artifact baseline
Installed1.6.0, bundle com.tristanmcinnis.quick-launch, macOS26, stamped d827bd9. Repo HEAD202a7365f68be05f23c898b778f41473442dddfe. Both pin HouseChatCore e9ebb6a and HouseDesign03dc7df (v1.0.0). Scout could read metadata but had no shell to measure executable SHA/signature or prove the intervening source diff. Parent follow-up: baseline-installed.json closes the identity/diff gap; baseline-verification.md records the full test run. This map retains the starting revision and source locators.

## Core workflow map

| Workflow | Source anchors | Test anchors |
|---|---|---|
| Quick AI entry | QuickViewModel.handleTab:3516, submitTypedText:3216; QuickAIHotkeyRegistration:22 | QuickAIHotkeyTests; QuickAIKeyboardTests:453,474 |
| Selected-text review/insertion | QuickViewModel PendingTransformReview:6004, review:9163, fail-closed write-back:10184, formatted paste:10259; +TransformInput:373; TransformReview:7 | QuickAIInputSafetyTests:63,85,105; FormattedPasteTests |
| Full chat/follow-ups | +AIChat.continueInAIChat:86; openAIChatWindow:145; AIChatWindowController:480,551,709; QuickViewModel queued follow-up:9360 | AIChatToolParityTests; AIChatWindowLifecycleTests; QuickAIKeyboardTests:314,361 |
| Explicit context/files/links/images | AddContextEntry; AttachmentTray:182,634; SharedDocumentExtractor:13; AttachmentExtractor; LinkAttachmentReader | AttachmentExtractorTests; LinkAttachmentReaderTests; AttachmentFlowTests; AttachmentPrivacyTests |
| Saved prompts/named inputs | SavedPromptResolver.resolveAction:36, argumentSlots:90, expansion:117; SavedPrompt.textOnly:142; TransformArgumentPane | SavedPromptsTests:92; SnippetPlaceholderTests; QuickAIInputSafetyTests:46,210 |
| Keyboard/focus | QuickViewModel Escape/shortcut stack; FocusRequest | QuickAIKeyboardTests; PaletteRailFocusProofTests:14,75,132 (separate keyboard-taking run) |
| Model/destination control | ChatRouteResolver.resolve:143; ModelProfile; QuickViewModel receipts:9110 | ChatRouteResolverTests; OpenAICompatibleServiceTests |
| Retention/cancel/recovery | ChatArchive durable turns:232,243,267, source status:634, tombstones:745; QuickViewModel deferred clear:10461 and settle:9291; AppDelegate.hideOverlay:758 | QuickAIAnswerRetentionTests (8 cases); DurableChatTurnTests; ChatHistoryRetentionTests |
| Surface instructions | QuickSettings systemPrompt/chatSystemPrompt:268, migration:763, surface selector:842; QuickViewModel:9840; ProviderSettingsView:296 | PromptSurfaceInstructionTests |
| Latency | QuickViewModel33ms coalescing:922; OpenAICompatibleService6 tool rounds/30s budget:138; answer timings:7978 | ChatPerformanceBaselineTests:72 covers render/flush/build; live entry-to-first-token unmeasured |

Paths are under Sources/ or Tests/ in this repo; line numbers locate source at the start of this goal and may drift as code changes.

## Source observations and remaining tests
- Source and tests implement all listed core workflows. Their real interactions and live-provider quality remain unmeasured in this goal.
- Quick AI and AI Chat share QuickViewModel; isAIChatWindow selects surface instructions/actions/close behaviour. ChatRouteResolver freezes a route; ChatArchive persists before inference and checkpoints during streaming.
- Selected-text accept re-reads the live selection and copies instead if it no longer matches. This needs a matched native edit test.
- One queued follow-up is deliberate. Whether that is enough versus Raycast must be assessed on actual core tasks.
- Files use HouseChatDocuments; link/clipboard/image paths use the app extractor. Duplicate extraction paths are confirmed, but output harm is not. Test identical bytes through routes before refactoring.
- Context sizing uses static model data and a UTF8-byte estimate with headroom. No served-window discovery or overflow retry was found in the bounded Sources/Tests scan. Reproduce overflow before selecting a fix.
- No live entry-to-first-token baseline was found. Existing timings/renderer tests do not establish a speed win.
- Prompt separation tests check wiring. Output quality needs a matched comparison. Past synthetic model results are not a Raycast head-to-head.
- ChatContextEvaluation contains legacy route/withheld-label properties not read by views; all enabled tools remain offered by policy. Do not revive a retired restriction merely to use dead fields.

## Next evidence
Live matched tasks for admission, safe edits, promotion, follow-ups, context and recovery; installed hash/signature/diff proof; baseline full suite; model-qualified timing measurements; held-out quality tasks. No superiority claim is supported by this map alone.
