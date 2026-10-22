# Independent internal baseline

2026-10-21. Verifier:ql-core-baseline-tests. Verdict:PASS. This is not competitive parity evidence.

- HEAD before/after:202a7365f68be05f23c898b778f41473442dddfe. No tracked/index changes; only the same five new comparison documents existed.
- `timeout -k 5 300 make test`:exit0, SCRUB_CLEAN,2424 tests in208 suites passed (61.805s test duration,136.42s wall including build).
- Pinned HouseChatCore at e9ebb6ab22442bce6c407a386712b0a2ecf4f9c6/tag v1.0.0:182 tests in18 suites passed using separate scratch output. Its checkout remained clean.
- `design-lint --no-color --baseline check`:clean,0 hits, baseline0,236 files.
- Expected skips:3 suites/8 tests (launcher performance1, chat performance4, native rail focus3). No latency result or native-focus claim follows from this run.
-14 build warnings repeat the existing LinkAttachmentReader.swift:75 unused-mutable-variable warning; no new failure.
- Platform:macOS26.5.2, Swift6.2.3, arm64. No other configuration sampled.

No live app/window control, provider/model calls, installation, production changes, commits, Keychain/profile/history reads or Git-config changes were performed. Raw logs are retained outside Git in the private comparison evidence's baseline-tests/ directory (00-meta.txt,10-make-test.log,20-housechatcore-test.log,30-design-lint.log,40-workspace.txt).

Parent separately measured the installed binary and verified its signature; see baseline-installed.json. Installed d827bd9 differs from repository202a736 only in the five listed publishing-hook files. No application build input differs.
