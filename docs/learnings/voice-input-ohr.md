# Voice input via ohr — post-mortem

Status: **removed in April 2026 after ~3 attempts. Never worked end-to-end.**

This document exists so the next person who thinks "let's bolt voice transcription onto apfel-quick by shelling out to `ohr`" understands what was tried, why it was *architecturally* appealing, and why it never actually transcribed a single word of user speech on an installed, signed, notarized apfel-quick.app.

If you're about to rebuild voice input: **don't start with a subprocess.** Skip to the "What to do instead" section at the bottom.

## What was built

- **Feature PRs:** #18 (voice-to-prompt via ohr), #19 (mic permission + bundled ohr + tabbed settings).
- **Follow-up fixes:** add `com.apple.security.device.audio-input` entitlement, single-line entitlement comments for the AMFI XML parser.
- **Release versions that shipped broken voice:** 1.0.5, 1.0.6.

### Architecture

```
┌────────────────────────┐     spawn     ┌──────────────────────────┐
│ apfel-quick (GUI .app) │ ────────────► │ ohr --listen -o json     │
│  - NSPanel overlay     │   stdout/JSON │   --language en-US       │
│  - QuickViewModel      │ ◄──────────── │   --quiet                │
│  - VoiceTranscriber    │               │ (on-device Speech fwk)   │
└────────────────────────┘               └──────────────────────────┘
```

- `VoiceTranscriber` (actor) spawned `ohr` as a child `Process`, piped stdout, line-split on `\n`, decoded each line into `VoiceSegment { id, start, end, text }` via `JSONDecoder`, yielded segments onto an `AsyncStream<VoiceSegment>`.
- `QuickViewModel.toggleVoice()` drove the lifecycle — it also called `AVCaptureDevice.requestAccess(for: .audio)` from the **parent** process because macOS TCC attributes the *child's* mic request to the parent bundle, and without a prior parent-side grant the child is silently denied.
- `AppBundledBinaryFinder` preferred `Contents/Helpers/ohr` inside the app bundle over PATH. The build script embedded `ohr` there and signed it **with the parent's entitlements** so TCC treated parent+child as a single identity.
- Info.plist declared `NSMicrophoneUsageDescription`.
- Entitlements declared `com.apple.security.network.client` + `com.apple.security.device.audio-input`.
- Tests: 200 → 210 unit tests added across `VoiceTranscriberTests`, `VoiceTranscriberRealOhrTests`, `BundledHelpersTests` (entitlement/embedding regression guards).

On paper every box was ticked. In production it never once produced text from live mic input.

## What actually went wrong

In rough order of discovery:

### 1. TCC prompt never fired (v1.0.4 → v1.0.5)

First build spawned `ohr --listen`. macOS TCC silently refused the child. No prompt, no entry under System Settings → Privacy → Microphone, no error — `ohr` just exited immediately.

**Root cause:** apfel-quick itself had never touched an audio API, so it had no TCC record. macOS assigns the "responsible" process for child mic requests to the parent; a parent with no mic history is treated as "denied, notDetermined" depending on OS version, and the child never gets to prompt.

**Fix attempted:** call `AVCaptureDevice.requestAccess(for: .audio)` in `VoiceTranscriber.start()` before spawning `ohr`. This was supposed to trigger the TCC prompt against apfel-quick's bundle ID using `NSMicrophoneUsageDescription`.

### 2. Hardened Runtime blocked AVCaptureDevice (v1.0.5 → v1.0.6)

After fix #1: prompt *still* never appeared. `requestAccess` returned `denied` synchronously. The app never appeared in System Settings → Privacy → Microphone at all.

**Root cause:** the build script signs with `--options runtime` (Hardened Runtime). Under Hardened Runtime, `AVCaptureDevice.requestAccess(for: .audio)` silently returns `denied` unless the entitlements plist contains `com.apple.security.device.audio-input`. No log, no crash, no TCC prompt — just a quiet `denied`.

**Fix attempted:** add the entitlement key.

### 3. Codesign AMFI XML parser rejected multi-line comments (v1.0.6)

Added the entitlement with a multi-line XML comment explaining *why* it was there. `codesign` itself accepted it; running the signed binary crashed at launch with an AMFI violation because the in-kernel XML parser is stricter than `codesign`'s and doesn't handle multi-line `<!-- ... -->` in the embedded `__TEXT,__entitlements` blob.

**Fix attempted:** collapse to single-line comments. Signed binary now launched.

### 4. It still didn't work

With all three fixes shipped (v1.0.6, signed + notarized + entitled), pressing the mic button on a fresh install: TCC did prompt once (progress!), user accepted, `ohr` spawned, and… no segments ever arrived on stdout. No error surfaced to the UI. The `for await seg in transcriber.segments` loop hung until the user pressed stop.

Several hypotheses never fully pinned down:
- `ohr --listen` may not have seen any audio frames even with permission, possibly because child-inherited TCC grants don't survive into a separately-signed helper's own `AVAudioEngine` instance in every macOS version.
- ohr 0.1.6 has known issues with `--listen` when stdout is a pipe (not a TTY) despite `-o json` being supposed to satisfy its "interactive or non-plain output" rule.
- stderr was redirected to `/dev/null` for cleanliness; any diagnostic that *would* have told us what failed was thrown away. **This alone delayed the diagnosis by days.** If you rebuild anything similar: capture stderr, log it to a rotating file, surface the last N lines in the Voice settings pane.

No combination of in-process permission requests, bundled helper signing, entitlement changes, or argv tweaks produced a single transcribed segment on the shipped app. It worked in `swift test` (against `/bin/echo` fakes and against `ohr` running on a *file* fixture — `-o json hello.m4a`). It never worked on live mic inside a distributed `.app`.

## Lessons that generalize

1. **TCC + subprocess + Hardened Runtime is a three-body problem.** Every one of those layers can silently return "denied" or "missing entitlement" without any log. If you must debug this combination, do it with `log stream --predicate 'subsystem == "com.apple.TCC"'` running in another terminal *from minute one*, not as a last resort.

2. **Never swallow stderr on an external helper that might fail in 40 different ways.** We did, and paid for it. Tee it to a file under `~/Library/Logs/<AppName>/` and surface the tail in the UI.

3. **Entitlement XML comments must be single-line.** `codesign` parses laxly, the kernel's AMFI XML parser parses strictly. If your signed binary launches fine in `codesign -dvvv` and crashes on `open /Applications/Foo.app`, suspect your entitlements XML before anything else.

4. **"It works on `swift test`" proves nothing about a shipped `.app`.** Unit tests ran against fakes; the integration test used ohr's *file mode* (`-o json file.m4a`) because live `--listen` from a test runner is a non-starter. Neither exercised the runtime path that actually matters: a signed, notarized, user-installed bundle spawning a bundled helper against a live microphone with a fresh TCC grant. Build that loop into `scripts/` before you ship.

5. **Cross-app TCC inheritance for signed children is not reliable across macOS versions.** Apple's public docs imply a bundled+co-signed helper inherits the parent's grant; in practice behavior varied across macOS 14, 15, 26. If you depend on this, test on at least two OS versions before you declare victory.

6. **Confirmation bias from "fixed" TCC prompts.** Each of the three fixes above *visibly* changed user-facing state (prompt appeared, app showed up in Privacy settings, binary launched). That kept masking the fact that the end-to-end transcription path still didn't work. Keep the acceptance test end-to-end — "I pressed the mic, I spoke, text appeared in the input field" — and refuse to call anything fixed until that test passes on an installed release build.

## What to do instead

If voice input is still wanted:

- **Use Apple's `Speech` framework in-process**, not a subprocess. `SFSpeechRecognizer` + `SFSpeechAudioBufferRecognitionRequest` runs inside apfel-quick's own sandbox, owns its own mic grant, has one (1) entitlement to worry about, and there is no child-process TCC inheritance puzzle to solve. It's also what apfel-chat does.

- **If you really need an external engine** (e.g. Whisper via whisper.cpp for offline privacy beyond Apple's), embed it as a **library** (static lib or XPC service inside the bundle), not as a CLI binary. An XPC service gets its own signed identity and its own TCC grant that you can reason about.

- **Keep `ohr` as a user-facing CLI**, which it already is. Users who want it can `brew install` it and pipe its output wherever they like. Don't re-bundle it into the GUI.

## Removed artifacts (for archaeology)

The following were deleted when this doc was written. `git log` will show them:

- `Sources/Services/VoiceTranscriber.swift`
- `Sources/Services/MicrophonePermission.swift`
- `Tests/VoiceTranscriberTests.swift`
- `Tests/VoiceTranscriberRealOhrTests.swift`
- `Tests/Fixtures/hello.m4a`
- Voice fields in `QuickSettings`, voice methods in `QuickViewModel`, mic button in `OverlayView`, Voice tab in `SettingsView`
- `NSMicrophoneUsageDescription` in `Info.plist`
- `com.apple.security.device.audio-input` in `apfel-quick.entitlements`
- `ohr` embedding + signing in `scripts/build-app.sh`
- ohr/entitlement cases in `Tests/BundledHelpersTests.swift`

Relevant commits:
- `3014518` feat(#12): voice-to-prompt via ohr
- `3e24b46` fix: voice input mic permission + bundled ohr + tabbed settings
- `12ee1ce` fix: add audio-input entitlement — Hardened Runtime was blocking mic
- `8dd0890` fix: single-line entitlement comments (codesign AMFI XML parser)
