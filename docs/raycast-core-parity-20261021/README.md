# Quick Launch / Raycast core comparison

Status on 2026-10-22: **no parity or superiority verdict yet**. No matched native task or comparative AI request has run. The internal fix is installed; comparative product quality remains unproven.

## Verified so far
- Current Raycast 2.8.2.0: installed identity/signature checked; 36 module/binary digests and 17 selected REA graph-node locators independently verified. [Shipped evidence](raycast-shipped-evidence.md) separates semantic-graph support, direct source reads and unknown runtime behaviour.
- [Quick Launch baseline](baseline-verification.md):installed d827bd9, with hook-only changes to the starting repository revision 202a736. [Identity](baseline-installed.json) records the measured binary.
- One [instruction-budget defect](context-instruction-reserve-fix-20261022.md) reproduced and fixed in commit `d419052`. Final independent gate: 2,433 Swift Testing cases, 23 XCTest cases, 182 pinned shared-package cases; scrub and design ratchet pass. The fix is [installed in build 27bd421](installation-20261022.md); bundle identity and restart were checked by an independent verifier. Live UI behaviour remains unverified.
- Original synthetic fixtures reproduce on the recorded toolchain and pass 546 structural checks. The eight held-out variants remain private; their hashes and mappings are recorded. They reuse templates and test unseen values, not new task structures.

## What is still required
The native desktop tool refused access despite approval through the question UI. A plain-chat native-window instruction has been requested. No alternate UI-inspection or test-control path was used. The authorized installation used the repository's normal installer; no permission settings were changed.

Before measurement, verify available model/configuration choices and each app's supported procedure, then freeze the final task manifest and rubric in a named commit. The current [protocol](protocol-proposal.md) and [task manifest](task-manifest-proposal.json) are **proposals**. This checkpoint is not that formal freeze.

The draft budget is 28 primary submitted turns, 10 held-out turns, 12 repetitions and 10 fix/retry turns per app, capped at 60. Keep a live ledger, count failures/retries and obtain more permission before exceeding it. Actual calls so far: Quick Launch 0; Raycast 0.

Then run the matched tasks, retain failures, fix demonstrated material gaps, rerun matched and held-out cases, and independently audit the full result. Verify the final installation and remote commits. Internal tests and feature lists cannot substitute for that work.

## Read in order
1. [Plan and acceptance contract](PLAN.md)
2. [Current implementation map](current-map.md)
3. [Official Raycast procedures](raycast-official-procedures.md)
4. [Current shipped-artifact evidence](raycast-shipped-evidence.md)
5. [Proposed protocol](protocol-proposal.md) and [fixture method](fixture-method.md)
6. [Progress, including failed checks and corrections](PROGRESS.md)

Raw vendor code, private captures and held-out-specific contents are outside Git. The public files contain original fixtures, our code/tests and bounded factual summaries only. Extension-store breadth, subscriptions, team features and RTI are outside this comparison.
