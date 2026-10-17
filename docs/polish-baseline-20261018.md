# Polish baseline, 2026-10-18

Unit A0 of the Raycast polish plan. Records how the show path is measured and
the numbers before any speed change. No behaviour change in this commit.

## Machine

Apple M5, macOS 26.5.2, debug `swift test` build, run on a machine with no
other builds going. Base commit 84efcc7.

## Existing opt-in budget (headless)

Method: `QUICK_LAUNCH_PERF=1 swift test --filter LauncherPerformanceBudgetTests`,
five consecutive runs. The test now prints its two timings (the assertions are
unchanged: each under 250 ms).

| Run | Catalog scan (262 apps) | 100 filters for "spot" |
|-----|-------------------------|------------------------|
| 1   | 32.5 ms                 | 91.4 ms                |
| 2   | 27.6 ms                 | 91.0 ms                |
| 3   | 31.0 ms                 | 90.7 ms                |
| 4   | 33.1 ms                 | 93.8 ms                |
| 5   | 31.0 ms                 | 91.6 ms                |

Median: scan 31.0 ms, filter about 0.91 ms per keystroke-sized pass (91.4 ms
for 100). Debug build, so release will be faster. This covers filtering only,
not the hotkey-to-pixels path.

## Show-path signposts (live, not yet sampled)

Subsystem `com.tristanmcinnis.quick-launch`, category `ShowPath`
(`Sources/Services/ShowPathSignpost.swift`).

- Interval `HotkeyToFieldFocus` (metadata `launcher` or `quick-ai`): begins when
  the global hotkey handler fires, ends when a launcher or composer field has
  its focus set. Events inside it: `PanelOrderedFront` (after `orderFront` and
  `makeKey`) and `FieldFocusApplied`.
- Interval `OpenQuickAI`: wraps `QuickViewModel.openQuickAI()` itself.

The end point is field focus applied, not a real key event: the app cannot see
a key before the field takes it, so focus is the last observable moment. An
interval that is still open when the panel hides is closed unrecorded.

How to read it:

- Instruments, os_signpost template, filter on the subsystem; or
- `log stream --signpost --predicate 'subsystem == "com.tristanmcinnis.quick-launch"'`
  while pressing the hotkey ten times.

Numbers: unmeasured. The hotkey needs the installed app and a human or UI
driver on a real display, which this headless run does not have. The first
unit that claims a show-path speed-up must record the median of ten presses
here, before and after, with the method above.
