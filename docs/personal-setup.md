# Personal setup (Tristan's Mac)

This page records how Quick Launch is wired on Tristan's own Mac, where every
optional integration is present. None of it is needed to build or use the
app. The README lists the integrations in general terms.

## The House server

- SSH alias `vault-vps` in `~/.ssh/config`. It is the default for
  `HouseServer.host` (`Sources/Services/HouseServer.swift`), so no setting is
  needed here. Another Mac can point the lanes elsewhere with
  `defaults write com.tristanmcinnis.quick-launch HouseServerHost <alias>`.
- Vault Search and the `search_vault` tool run
  `vault-search.py` from the vault checkout on the server
  (`SSHVaultSearchService.remoteVaultRoot`), with an 8 second deadline and no
  retry. Source paths map back to the local clone at `~/vault`.
- SearXNG web search runs `curl` against `127.0.0.1:8888` on the server.
- The page-reader fallback runs the trafilatura reader in
  `~/search-tools` on the server for pages under 200 characters of text.

## Memory, tasks and skills

- `recall` (from the memory-recall repo) searches `~/memory` and reads the
  canonical task backends. The Memory and Tasks tools and Capture to Memory
  (`Option+Command+M`) call it with an argv array, no shell.
- Skills are read from `~/.claude/skills`.

## Other House pieces

- AI Chat is the House's general chat. RTI keeps its own chats because they
  are grounded in a meeting or a recording session.
- Quick Launch and RTI both pin house-chat-core by GitHub URL and tag
  (extracted from `Packages/HouseChatCore` on 2026-10-16), and take the
  design tokens from design-system the same way.
  `scripts/stamp-package-pins.py` stamps the pinned versions and revisions
  into the app's Info.plist.
- Quick Launch keeps no screen history of its own. The one screen-history
  collector is `screenctx` (memory-screenctx); Memory.app switches it on and
  off. Quick Launch's own collector was retired on 2026-09-26.
- The Local Models provider points at the local-models daemon on
  `127.0.0.1:8078`.
- The house Swift rule is `../design-system/SWIFT.md`. This repo is its
  reference implementation (macOS 26, swift-tools 6.2, Swift Testing).
- The Claude Code hooks in `.claude/` run `../design-system/bin/design-lint`
  when that sibling repo is present, and do nothing otherwise.

## Install

`make install` from a clean tree replaces `/Applications/Quick Launch.app`.
Local builds use the stable designated requirement
`com.tristanmcinnis.quick-launch`, so Accessibility approval survives
rebuilds. The `build` folder is excluded from Spotlight so it does not show
up as a second copy.
