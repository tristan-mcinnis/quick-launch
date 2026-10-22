# Proposed matched-task protocol

Status:DRAFT, not frozen. Independent protocol analyst prepared this before observing any runtime outcome. Parent corrected stale pre-update assumptions using current-map.md and baseline-installed.json. Model availability, fixtures, holdout files and hashes must be settled before the first measured task.

## Scope and claim
Seven domains:D1 Quick AI; D2 selected-text edit/insertion; D3 full chat/follow-ups; D4 explicit context; D5 saved prompts/arguments; D6 keyboard/focus; D7 retention/recovery/model route. EN and ZH both matter. Extension stores, billing and team breadth do not count.

Feature presence is not a win. A relevant core task attempted through the documented/labelled routes and shown to be unsupported may count; an unobserved or unexplored route is unknown. State precisely which builds/configurations and tasks support any superiority conclusion. Do not generalize to every Raycast feature or user.

## Two lanes
A:observable app behaviour, including focus, interactions, insertion integrity, preservation, disclosure and timing. B:blind scoring of output accuracy, instruction adherence, source fidelity, language and format fitness. Prefer a common model; otherwise retain normal-configuration product results with explicit model qualification rather than pretending the model difference is app-owned. Never ask the model to identify its own route; inspect app/request/receipt metadata.

Critical errors:E1 wrong-target write; E2 work lost contrary to the requested/stated preservation outcome; E3 source carried across a new-chat boundary; E4 a route differing from displayed/selected/recorded routing; E5 overwrite outside the target selection. Quality and safety gate speed: speed cannot offset an incorrect or unsafe result.

Starting meaningful deltas: 3 user actions; 150 ms app-side only if instrumentation resolves it; 1 point on a 1-5 blind rubric. A timing win requires `candidate_median <= 0.8 * comparison_median` and at least one second saved. Report all trials, medians and ranges. Unknown or under-resolved timing cannot carry a win.

Parity requires no material deficit across the seven domains, zero Quick Launch critical errors, and no unresolved EN/ZH quality gate. Superiority requires parity plus reproducible wins in at least3 core domains: at least2 on actions/completion time and at least1 on correctness/fidelity/recovery/disclosure. Every claimed win must reproduce on a held-out variant. This operationalizes superiority for the specified personal workflows, not universal superiority over Raycast.

## State, order and observation
- Same synthetic inputs, target caret/selection, comparable saved prompts and retention intent. Follow each app's documented entry/cancel route, not the other's shortcut. File/image tasks use a surface that each app supports; record necessary promotion and its cost rather than declaring an unexplored surface absent.
- Do not access real chats, clipboard history or client material. Isolate irrelevant personal-data tools through visible controls if needed, record changes and restore them; no hidden product tool restrictions.
- Record artifact identities and model/tool/route setup before and after each block. Counterbalance app order across blocks. One operator is a stated limit.
- Client-first request is the only justified cold label; provider/cache coldness is unknown. No repeated quits that could discard a draft.
- Rich-text integrity means unchanged text and attributes outside the selection, not byte-identical RTF serialization. Missing-input error language is not a localization requirement. The already-selected routine model/provider label is sufficient; non-routine destination must be made clear.
- Local URL listener silence proves only no observed local request. It must not become a claim of no cloud-side fetch. A no-fetch superiority claim needs an observer that covers the actual execution path.

## Primary tasks

| ID | Domain | Synthetic task | Required observation |
|---|---|---|---|
| T01 | D1 | Rewrite memo to≤90 words, retaining four figures and two dates | Correct constraints, no new facts, interactions/time |
| T02 | D1 | ZH-to-EN client-style translation with two glossary terms and dates | Both terms, dates, grammatical language, no invention |
| T03 | D1 | Extract delivery dates for four suppliers, two unstated | Exactly two stated dates and two explicit absences |
| T04 | D2 | Shorten selected paragraph in rich text; review then accept | Target changes once; surrounding text/attributes stay intact |
| T05 | D2 | Change target selection after submission, before accepting | Revalidation/refusal, no wrong-target write |
| T06 | D2 | Formalize mixed ZH/EN text | Named terms/abbreviations preserved, valid punctuation/spacing |
| T07 | D3 | Quick AI summary, promote to chat, shorten in follow-up | Complete history/source retained; no duplicate turn |
| T08 | D3 | Three turns:three risks, one mitigation each, preserve order | Stable3-item ordering and mapped mitigations |
| T09 | D3 | Submit another question during streaming | Single queued/send or clear refusal preserving draft; no loss/duplication |
| T10 | D4 | Attach policy, quote the clause on returns after30days | Exact clause/id, no invented terms; longer source variant required |
| T11 | D4 | Shorten paragraph containing URL, explicitly do not open it | Correct output and bounded canary observation, with coverage limits |
| T12 | D4 | Read four chart values and total from image | Exact values/total; selected or non-routine route evidence |
| T13 | D5 | Invoke saved prompt with audience/tone/length defaults | Only missing values requested, defaults applied, no instruction retyping |
| T14 | D5 | Invoke selection-dependent ZH prompt with no selection | Clear missing-input state, no empty submission or silent clipboard substitution |
| T15 | D5 | Submit with required argument empty, then fill it | Initial send blocked, then exactly one request |
| T16 | D6 | Complete a normal quick task using keyboard only | No pointer requirement; entry and completion observations |
| T17 | D6 | Half-type a question, Escape twice | Origin focus/caret restored; no unintended submission |
| T18 | D6 | Invoke hotkey twice rapidly, submit once | Single panel and request, no lost draft |
| T19 | D7 | Separate dismiss/reopen and cancel-partial scenarios | Work accessible as promised/requested; no suffix-only answer or silent loss |
| T20 | D7 | Declared unreachable endpoint, then normal-model retry | Useful error/recovery, no duplicate answer; unsupported counterpart recorded honestly |
| T21 | D7 | Switch model and submit next turn | UI/request/receipt routing agreement, no silent fallback |
| T22 | D4/D7 | New chat after policy task, ask source-only control-code question with no attachment | No old-source carryover; explicit absence rather than invention |

Parent pre-freeze additions:T22 makes the source-boundary gate explicit; T10 includes a longer realistic research source; T19 distinguishes dismissal from cancellation rather than conflating them. These are not post-result changes: no live outcome has been observed.

## Budget and holdout
User permits up to60 submitted synthetic AI turns/attempts per app for this stage. Count multi-turn, failed attempts and retries; keep a live ledger. Do not silently exceed the cap or drop required coverage. Ask for more if the fix/retest loop needs it.

The current task manifest allocates 28 primary turns, 10 held-out turns, 12 repeated turns and 10 fix/retry turns. An independent verifier recounted this total of 60 per app. The repeats cover timing and safety; multi-turn and failed-endpoint attempts are counted. Preserve the fix reserve and repeated observations for every claimed efficiency win.

Eight held-out variants now exist outside Git. Their domain mapping and full hashes are in fixtures/holdout-manifest.json. They require 10 turns and reuse some templates with unseen inputs. The parent has not read the held-out-specific contents. They remain pending the formal protocol freeze. Reveal them only after primary results are locked; publish later for reproducibility.

## Gap loop and freeze
Every failed criterion enters a gap register with raw evidence, reproduced cause, smallest coherent fix, regression proof and matched/held-out rerun. Never replace a failing metric with an easier one. Before measurement, commit the final protocol, primary fixtures, scoring rules and holdout hashes. Later amendments must be dated, additive and visible. No comparative verdict exists yet.
