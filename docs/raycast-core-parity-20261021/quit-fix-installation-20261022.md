# Quit-preservation fixes installed

Build **`798c121` is installed** at `/Applications/Quick Launch.app`. It includes the instruction-budget, quit-preservation and submission-ownership corrections. Artifact identity is verified; native workflow quality and Raycast parity remain unproven.

## Installation and verification

The user approved restarting after a warning about unsent text and streaming answers. The old installed build, `27bd421`, predates the new quit guard. Its shutdown must not be described as loss-free.

The parent preserved the old bundle, then ran the normal installer from clean, committed source. An untracked wrapper makefile outside the repository checked and captured the fresh signed bundle before replacement. The installer attempted a polite quit and confirmed exit. It has no TERM or KILL fallback. The parent then ran `make run`.

| Check | Verified result |
| --- | --- |
| Installed source | `798c121283f2682971c9c37a55334651b36aca31` |
| Version / platform | 1.6.0; arm64; macOS 26 minimum |
| Installed executable SHA-256 | `8c18aea387d94692e65bd244ed94752a0cb3d4940664443f05ceca1873f8ebf7` |
| Fresh-input match | All seven installed file hashes and the Info.plist match the capture made before replacement |
| Signature | Strict/deep verification passed; same Apple Development identity, TeamIdentifier, designated requirement and network-client entitlement |
| Package pins | HouseChatCore 1.0.0 at `e9ebb6ab22442bce6c407a386712b0a2ecf4f9c6`; HouseDesign 1.0.0 at `03dc7dfdf369641f19107478fae62dee9f904878` |
| Rollback | All seven prior bundle hashes preserved; stamp `27bd421`; strict signature valid |
| Startup observation | Parent observed new PID 35518 alive after 10 seconds, with old PID 15482 absent from the app processes, at `2026-10-23T00:43:23Z` |

An independent artifact verifier rechecked the installed and rollback files, metadata, signature, pins and capture ordering. It did not query processes; startup liveness above is the parent's observation.

The preflight build had executable hash `b98dfdfcea42847af544811c93b1281299948ba3f20a65216eea8e7655927681`. The installer rebuilt and re-signed, so the installed hash was compared with the fresh installer capture, not that earlier hash. No tracked build or installation recipe was changed for the receipt.

## Rollback and limits

The local rollback bundle is at this path relative to the repository:

```text
../.release-2026-10-22/rollback/20261023T003600Z/Quick Launch.app
```

Its executable hash is `c6944da92b0a0d180afb2117bdc6b484e79c6ba3adaacd593ad41d12dfbc1fc5`. Restore it only after a safe quit. The installer must refuse replacement while the current app is still running or its state is unknown. Source-level rollback is documented in [the fix evidence](quit-preservation-fix-20261022.md).

The installation scripts replaced only the app bundle. They did not read, copy or delete user preferences or chat archives. Normal app startup is separate from those scripts; no claim is made that user data stayed byte-identical.

Unverified: native UI/hotkeys, real quit/relaunch recovery, live `NSApp.reply`, the refusal alert, shutdown data integrity, actual Keychain access and TCC permission continuity. Matching signature metadata is not proof of working credentials or permissions.

Private receipts and logs are in `install-quit-fix-20261022/` in the local comparison evidence directory. Comparative attempts remain **Quick Launch 0/60; Raycast 0/60**. The protocol remains proposed and the held-out inputs remain sealed.
