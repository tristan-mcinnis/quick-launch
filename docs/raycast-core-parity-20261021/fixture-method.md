# Fixture method

Status: fixtures built and validated; protocol and manifest are still PROPOSED, not frozen. Parent owns the freeze, the live runs and the commit. No task has run and no outcome has been observed.

## What is here

Sixteen primary fixture units in `docs/raycast-core-parity-20261021/fixtures/`, one build script and one holdout hash manifest. All content is original and synthetic. Nothing is copied from the vendor, from a client record, or from a real policy.

| Unit | Path | What it carries |
|---|---|---|
| memo-en | `text/memo-en-pilot.md` | 328-word memo. Four numeric facts: 1,240 units, 18 percent, 6 weeks, 2 open findings. Two delivery dates: 2026-11-14 (A), 2026-12-03 (B). Suppliers C and D unstated. Three risks in one stated order. |
| memo-zh | `text/memo-zh-pilot.md` | Chinese memo with 供应链 and 复购率, 800 units, two ISO dates. |
| url-paragraph | `text/url-paragraph-canary.md` | Literal `CANARY_URL` placeholder plus `https://canary-url.invalid/memo-2026`. Never a real or private URL. |
| mixed-note | `text/mixed-zh-en-note.md` | Mixed ZH/EN note with SKU-A12, SKU-B7, MOQ, 600 pcs and two numbers. |
| canary-notes | `text/unrelated-canary-notes.md` | Unrelated office note carrying `NOTE-CANARY-4471`. |
| richtext-rtf | `richtext/richtext-target.rtf` | Six paragraphs; bold, italic, underline and three sizes; target is paragraph 3. |
| richtext-canonical | `richtext/richtext-target.canonical.txt` | Canonical plain text for selection offsets. |
| richtext-expected | `richtext/richtext-target.expected.json` | Expected text and per-run attributes, plus target offsets. |
| returns-pdf | `documents/returns-policy-2page.pdf` | Two pages, selectable, clause IDs RP-1.1 to RP-9.3, control code `QX7-4418-RET`, late-return clause RP-4.2. |
| supplier-docx | `documents/supplier-policy-long.docx` | 1,627-word policy pack; Schedule C is late in the document and holds clause SP-9.3 and control code `LT9-6205-SUP`. |
| chart-png | `images/chart-monochrome.png` | 1-bit monochrome, 1200x800, values 12/27/9/34, total not printed. |
| prompt-digest | `prompts/saved-prompt-digest-en.json` | Saved prompt, three named arguments, all with defaults. |
| prompt-zh | `prompts/saved-prompt-zh-summary.json` | Chinese saved prompt that requires a selection. |
| prompt-brief | `prompts/saved-prompt-supplier-brief.json` | Saved prompt with one required argument and no default. |
| routes | `routes/route-slots.json` | Logical route slots: routine, non-routine, declared unreachable (`127.0.0.1:9`). |
| facts | `fixture-facts.json` | Literal expected facts read by the validator. |

`generate/generate-primary-fixtures.py` rebuilds every primary unit byte-for-byte. `SHA256SUMS` pins all 19 files, including the generator and the holdout hash manifest. `validate_fixtures.py` re-checks all of it and must print PASS. The generator takes `--output-dir DIR` so a rebuild can be written to a scratch copy and compared without touching the working tree. The folder is `generate/` rather than `build/` because this repository ignores `build/` and Git would never see the file.

## Design decisions

- **Rich text is judged semantically.** T04 and T05 are scored on text and per-run attributes (bold, italic, underline, size) inside and outside the selection. Byte-identical RTF serialisation is explicitly not a criterion, so a different RTF producer cannot fail the task and a different vendor's serialiser is not a fixture property.
- **The chart total is computed, not printed.** The four bars are labelled; 82 is not on the image, so T12 checks both reading and arithmetic.
- **The URL cannot resolve.** `.invalid` is reserved by RFC 6761. Any fetch must fail, so T11 can only support "no successful retrieval". It cannot support "no attempt" and cannot say anything about a cloud-side fetch. That limit is written into the task and the fixture facts.
- **Control codes and canaries are unique per document.** Two primary codes (`QX7-4418-RET` in the returns PDF, `LT9-6205-SUP` in the long policy) and one unrelated-note token (`NOTE-CANARY-4471`). The holdout set carries its own distinct codes, which are not published here. An unexpected code in a fresh chat is evidence to investigate for source carryover or another input path. Its absence in T22 means no leak was observed in that probe; it does not prove that every source boundary is sound.
- **Dates are ISO inside prose.** That keeps translation, extraction and rewrite checks literally comparable across apps instead of arguing about "14 November" versus "November 14".
- **Digits are rationed in the memo.** After dates are removed, the only digit runs are the four facts. A rewrite that invents a fifth figure fails the task criterion.
- **Prompts are logical, not vendor-specific.** Route slots are labelled `route-default`, `route-alt`, `route-unreachable`; model identifiers, keys and endpoints of real providers appear nowhere. The operator records the real label in the run log.
- **Retention is scored against each app's own control.** T19 does not equate Raycast's keep/discard vocabulary with any Quick Launch setting such as DoNotKeep. Each app is judged against the promise its own visible dismiss or stop control makes, and the same user preservation intent is scored in both.

## Calls and budget

Recalculated from the manifest, not assumed:

| Block | Calls |
|---|---|
| Primary T01-T22 | 28 |
| Holdout H01-H08 | 10 |
| Repeated timing and safety | 12 |
| Fix and retest reserve | 10 |
| **Total per app** | **60** |

The draft estimate was 27 primary turns with an 11-turn reserve. The task-level recount gives 28: T10 carries the required long-source second case, and T20 counts its declared failed attempt. One turn moved from the reserve to primary, so the reserve is 10 rather than 11. No task or criterion was dropped, and no coverage was traded for budget.

Multi-turn tasks: T07 2 turns plus one promotion that submits nothing; T08 3; T09 2; T10 2 (one per source); T19 2 (dismiss, then cancel); T20 2 (failed attempt, then retry); T21 2. Zero-send tasks: T14 and T17 submit nothing; T15 submits once only after the empty submit is blocked. An unexpected send in any zero-send task is charged against the reserve.

Request counts are submitted test turns and attempts per app. Internal vendor API calls are not observable and are never counted, assumed or inferred.

## Holdout

Eight original variants covering all seven domains, 10 calls in total, held outside Git under `<private-root>/holdout/v1-20261022/` (the goal evidence directory, not a repository path) with directory mode 700, generated assets at mode 600 and the private builder at mode 700. Only IDs, domains, criterion focus, call counts, file counts and per-variant hashes are published, in `fixtures/holdout-manifest.json`. No holdout-specific input or expected answer is published at this stage. Variants reuse some generic prompts, document templates and formatting. They test transfer to unseen fixture values, not wholly unfamiliar task structures.

The operator must not read or run a holdout file until the primary results are locked and the parent has committed the primary manifest. Holdout contents become publishable only after that point.

Domain coverage: D1 H01; D2 H02, H07; D3 H03; D4 H04, H05; D5 H06; D6 H07; D7 H05, H08. Follow-up and recovery depth is carried by H03 (two turns) and H08 (cancel partial, then a new-chat source question).

## Validation

`python3 fixtures/validate_fixtures.py` runs 546 checks with no network and no app launch:

- every JSON fixture parses and carries its required keys
- memo word count, the four numeric facts, both dates, four suppliers, the two unstated dates and the risk order
- glossary terms and dates in the Chinese memo; the CANARY_URL placeholder and the absence of any other URL
- the RTF parses to the canonical text and to the expected run attributes, and the target offsets slice the stated target
- the PDF is exactly two pages with 20+ clause IDs, one control code, and the T10 sentence exactly once in a real text layer
- the DOCX parses, is over 1,500 words, holds the late clause and code in the last quarter, and repeats no paragraph more than twice
- the PNG is 1-bit, 1200x800, and its values match the fact index
- the saved prompts have the argument shape the tasks assume
- the manifest covers T01-T22, every reference exists, every fixture is used, turn submits equal the declared calls, and the four budget blocks sum to 60
- `SHA256SUMS` matches the bytes, and the token scan covers every fixture file, including the PDF and DOCX bytes. PNG bytes are compressed, so the generic token check is applied to them but the prose check is not; the image is validated structurally instead. Absolute home paths, house paths, vendor names and key material are refused. Client and colleague names are not listed in the tracked validator at all: they are read from the untracked `.scrub-private` file when present, and matches are reported as a count only, never as a name.

Determinism is checked by rebuilding twice and comparing hashes; the DOCX package is rewritten with fixed entry timestamps so its bytes do not drift with the wall clock. The build records its toolchain in `fixture-facts.json`: Python 3.14.7, Pillow 12.3.0, and Pillow's bundled default bitmap font loaded at an explicit size, with no system font file read. The chart and PDF bytes are therefore pinned to those versions; after any Pillow or Python change, regenerate and compare `SHA256SUMS` before trusting a hash.

## Rebuild and publish discipline

- `generate/generate-primary-fixtures.py` writes in place by default and honours `--output-dir DIR` for a scratch rebuild. Compare the scratch tree with `SHA256SUMS` before replacing anything.
- The private holdout builder rebuilds its own assets by default and will not touch the repository hash manifest unless it is given `--publish-manifest`. A plain rerun therefore cannot overwrite a frozen public manifest by accident.
- Git sees every candidate: the folder is `generate/`, not `build/`, because this repository ignores `build/`. `git status -uall` lists the generator, every fixture, the validator and both manifests.
- The publish scrub is `scripts/scrub.sh` over tracked files, plus the untracked `.scrub-private` token list. The tracked validator carries no client, colleague or employer name; those live only in the untracked list.
- The 1,627-word policy pack is a long-source fidelity case: it tests whether an answer finds a late clause in a realistic document. It is not a context-window stress test, and no claim about maximum context is made from it.

## Limits

- No task has run. Every criterion is a proposal, not a result.
- The `.invalid` canary bounds T11 to no successful retrieval.
- Timing depends on provider and machine; the repeat block exists to expose the spread, not to hide it.
- One operator is a stated limit of the design.
- The manifest is not frozen until the parent commits it and records the fixture hashes at freeze time.
