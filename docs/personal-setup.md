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

## Chief of Staff

AI Chat is the face of the `cos` organ (the chief-of-staff repo). Quick Launch
reads its thread under `~/.local/share/chief-of-staff` and acts only through
the `cos` CLI at `~/.local/bin/cos` (`COS_HOME` and `COS_BIN` move both). The
contract is `../chief-of-staff/docs/CONTRACT.md`.

The pinned conversation sits at the top of the AI Chat list: health in its
status line, then DECIDE, TODAY, WAITING ON OTHERS, PROJECTS, LATER and FYI
above the chat, or a Board (`Option+Command+2`). On a card, `Command+Return`
Do it, `Command+E` Edit, `Command+L` Later, `Command+Delete` No, `Command+R`
Bring back, `Command+=` and `Command+-` More and Less, `Command+Z` Undo,
`Command+D` Discuss in a new chat; `Command+N` adds a task. Activity,
Artifacts and Charter are `Option+Command+3` to `Option+Command+5`. Its
notifications come from Quick Launch. Type `cos` in the launcher to open it.
This pinned conversation is the only Chief of Staff face; the old
ChiefOfStaff.app is retired.

## Other House pieces

- AI Chat is the House's general chat. RTI keeps its own chats because they
  are grounded in a meeting or a recording session.
- RTI builds `Packages/HouseChatCore` from `../../quick-launch` (this repo),
  so the package keeps its path and public API.
  `scripts/chat-core-provenance.py` stamps its source fingerprint into both
  apps' Info.plist.
- Quick Launch keeps no screen history of its own. The one screen-history
  collector is `screenctx` (memory-screenctx); Memory.app switches it on and
  off. Quick Launch's own collector was retired on 2026-09-26.
- The Local Models provider points at the local-models daemon on
  `127.0.0.1:8078`. Read aloud uses Local TTS on `127.0.0.1:8081`.
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
