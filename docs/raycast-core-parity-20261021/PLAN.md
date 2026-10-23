# Quick Launch versus Raycast: core parity and superiority

Started 2026-10-21. Active goal:02ec5cf3-dd93-4566-94ff-2dc0e465cc3c.

## Objective
Establish product parity and demonstrable superiority for one person's core Quick Launch workflows, compared with the current installed Raycast. Use subagents and reverse-engineer-anything. Fix demonstrated gaps, independently verify them, and publish rollback-friendly code and evidence commits. Feature existence and passing internal tests alone do not establish competitive quality.

## Core scope
Quick AI; selected-text transformation and safe insertion; full chat and follow-ups; explicit context, files, links and images; saved prompts and named inputs; keyboard/focus interactions; retention, cancellation and recovery; model/destination control and task latency. Map these to the earlier Raycast review and actual product before freezing the task set. Test ordinary launcher entry/navigation where it serves these workflows. Do not count extension stores, subscriptions, monetization, team/admin features, or breadth for its own sake. RTI is not part of this goal.

## Evidence contract
1. Record current installed artifact identities, app source revision and configuration relevant to the comparison. Old reports are locators, not current proof.
2. Use REA on current shipped Raycast artifacts; trace concrete core behaviours. Distinguish static implementation, observed runtime and unknowns. Do not copy vendor implementation into Quick Launch.
3. Freeze matched synthetic tasks and a scoring rubric before observing outcomes. Separate model-dependent quality from app behaviour. Record setup differences and confounds, counterbalance order, repeat timing trials, and reserve held-out cases for verification.
4. Require no material deficit on essential core workflows, no critical safety/data-loss defect, and meaningful measured advantages across core outcomes. Unsupported or unobserved competitor behaviour is unknown, never a Quick Launch win. Do not declare superiority from a weak test designed to favour us.
5. Reproduce each demonstrated gap, implement the smallest coherent correction, run regression tests and repeat the same comparative task plus held-out variants. Do not replace a failed metric with an easier one after seeing results.
6. Independent verifier executes checks; independent reviewer audits claims and diffs. Completion requires a requirement-by-requirement evidence audit and real head-to-head runtime proof, not only a checklist.

## Safety and ownership
- Parent alone owns live native UI, commits, remote verification and installation. Coordinate keyboard control; do not interrupt a draft or recording. Live AI requests use synthetic content only and require the bounded test permission.
- Workers own disjoint code/test scopes after the gap inventory. Scouts/researchers/reviewers do not edit production source or installed apps.
- No environment dumps, secret reads, Keychain/profile exports, Git-environment simulations in a real repository, or changes to global Git/OS permissions. Never use personal chats, clipboard history or client documents as fixtures.
- Raw vendor code, binaries, private runtime captures and unsanitized screenshots stay outside Git in the local comparison evidence directory. Commit only original fixtures, bounded public factual summaries, sanitized measurements, methods and our code/tests.
- Keep existing House design, Swift6.2/macOS26 floor, tool policy and product boundaries. Do not revive retired ambient collection or Chief of Staff features.
- Use the approved local publishing hooks. No manual/force push, bypass, or skipped test gate. Record baseline and each reversible fix commit; prefer git revert instructions over destructive reset.

## Stages
1. Parallel: current Quick Launch map; current Raycast REA; official interaction documentation; independent matched-task design.
2. Consolidate scope, freeze protocol, obtain/coordinate live test access, capture baseline outcomes.
3. Parallel disjoint fixes for demonstrated gaps; parent serializes live comparisons.
4. Independent regression, matched and held-out reruns; refine until core parity and superiority are supported.
5. Publish sanitized evidence and code, verify remote revisions, safely install any final app build, and audit all requirements before completing the goal.

## Rollback baseline
Repository main and origin/main:202a7365f68be05f23c898b778f41473442dddfe, clean at goal start. Installed baseline d827bd9 has been re-measured; see baseline-installed.json. Since then, the instruction-reserve correction passed independent code and test review, was published as dedicated reversible commit d419052, and was installed in build 27bd421 after explicit restart approval. See installation-20261022.md for the independent artifact/restart checks and their limits. The separate quit-preservation correction is published as `24441c1`, with safer installer commit `e6b669b`. Its overlapping-submission follow-up is committed as `07f0428`. The final source passed independent review and 2,502 tests but remains uninstalled. See [quit-preservation evidence and rollback](quit-preservation-fix-20261022.md). Draft comparison materials remain a checkpoint, not the formal protocol freeze or a superiority verdict.
