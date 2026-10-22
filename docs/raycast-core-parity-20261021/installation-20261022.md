# Quick Launch installation, 22 October 2026

The instruction-reserve fix is installed and the app has restarted. This verifies installation only. The Raycast comparison remains unrun.

## Installed artifact

- Installation verified at 2026-10-22T20:06:28Z.
- Source: `27bd42146cc611d02020a6f57beae518da7aee7c`, including fix `d419052`.
- Version: 1.6.0; bundle: `com.tristanmcinnis.quick-launch`.
- Executable SHA-256: `c6944da92b0a0d180afb2117bdc6b484e79c6ba3adaacd593ad41d12dfbc1fc5`.
- Installed executable bytes match the build captured just before replacement. All 20 Info.plist keys match that build.
- Strict, deep signature verification passed. Team `QHCFP5472F`, designated requirement and entitlements match the previous installation.
- HouseChatCore v1.0.0 revision `e9ebb6ab22442bce6c407a386712b0a2ecf4f9c6`; HouseDesign v1.0.0 revision `03dc7dfdf369641f19107478fae62dee9f904878`.
- One new process was running from `/Applications/Quick Launch.app` after restart. The previous process was gone. An independent check found the new process still running about 2.5 minutes later and no matching crash report.

## Procedure and rollback

A separate worker built and checked the signed release. The parent preserved the old `d827bd9` app, verified its signature and matched its executable to the baseline digest. The rollback bundle and full receipts remain outside Git.

The user approved restarting after a warning about possible loss of unsent text or a streaming answer. The parent used the existing `make install` recipe with the established signing identity, then `make run`. A receipt-only Makefile dependency captured the built hash and plist before the installer removed its staging bundle. No dirty-tree override, ad-hoc signing or manual force-kill was used.

The source was clean and published before installation. The normal publication gate had passed 2,433 Swift Testing cases and 23 XCTest cases; the earlier independent shared-package gate passed 182 cases. These are internal checks, not competitive results.

## Limits and next check

The independent verifier checked bundle metadata, signatures, process identity and the rollback copy. It did not inspect private chats, settings values, credentials or clipboard history. Live UI behaviour, provider access, TCC permissions and shutdown data integrity remain unverified. Matching signing identity supports expected permission continuity but does not prove it.

The shutdown review found a possible gap between the final streamed text in the legacy cache and the authoritative archive. Unsent drafts are also memory-only. These source observations are recorded for a separate deterministic reproduction; no new retention fix is claimed here.

The desktop tool still refuses native-window inspection at its intent gate. No alternate UI-inspection method was used. Comparative requests remain zero for both apps; the task manifest is still not frozen.
