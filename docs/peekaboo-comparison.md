# Peekaboo vs Type to Click (2026-08-30)

Repo: https://github.com/openclaw/Peekaboo (MIT, 5,074 stars, 390 forks,
started May 2025, pushed 2026-08-29, very active, Swift, macOS 15+). Started
by Peter Steinberger (steipete), now under the OpenClaw org.

## What Peekaboo is

Eyes and hands for AI agents, as a CLI and an MCP server. `see` captures a
screenshot plus an Accessibility map with opaque element IDs; `click`, `type`,
`press`, `scroll`, `drag`, and `set-value` act on those IDs; `app`, `window`,
`menu`, `dock`, `dialog`, and `space` cover system surfaces; visual question
answering through local or remote vision models covers what the tree cannot.
Consumers are Claude Code, Cursor, and its own `agent` command. Its bet:
Accessibility first, pixels as fallback. Wherever a tree exists that beats
pure pixel CUA (screenshot in, coordinates out) on cost, speed, and
reliability; pixel CUA remains for treeless surfaces (canvas, games, VMs,
remote desktops).

## What Type to Click is

A human-lane overlay inside Quick Launch (`⌃⌥C`): a bounded Accessibility
scan of the focused window plus the active app's full menu hierarchy, gold
badges carrying real control names (no generated hint codes, by design),
fuzzy search over labels, roles, and menu paths, semantic
Press/ShowMenu/Confirm/focus first with a guarded coordinate click as
fallback, revalidation before acting, and continuation modes for chained
steps.

## Same substrate (independently converged)

| Layer | Peekaboo | Type to Click |
|---|---|---|
| Sensing | AX tree walk, structured element map | AX tree walk with depth/element budgets |
| Filtering | actionable elements, labeled | roles + semantic actions, labeled |
| Acting | semantic AX action, synthetic events as fallback | same order: AXPress family, then guarded CGEvent click |
| Staleness | "refreshed evidence" re-capture | rescan on scroll/display change, revalidate before use |
| Menus | first-class `menu`/`menubar` commands | menu bar and closed-menu commands as first-class targets |
| Runtime | native Swift | native Swift |

## Where they split: the brain

| Dimension | Peekaboo | Type to Click |
|---|---|---|
| Consumer | AI agent in a see-act loop | human typing in real time |
| Addressing | opaque stable element IDs handed to a model | no codes; visible names, roles, menu paths |
| Evidence | screenshots kept, vision QA fallback | none kept; badges drawn over the live UI |
| Scope | system-wide: apps, windows, spaces, dock, dialogs | focused app plus its menus, one action at a time |
| Surface | CLI + MCP | overlay UI |
| Latency tolerance | seconds, retries, model calls | must feel instant, no model in the loop |

## Where Peekaboo fits the stack

The agent lane already exists outside Quick Launch: `cua-driver` (AX hands) +
`dscomputer` (DeepSeek vision brain) + `dsbrowser` (browser lane). Peekaboo is
a maintained, MIT, Swift-native build of exactly that hands layer with an MCP
surface. Three uses worth a trial, all outside this repo:

1. Candidate upgrade or replacement for `cua-driver`'s hands.
2. UI testing: an agent session drives and verifies Quick Launch's own
   overlay during development.
3. Its vision fallback can point at the `local-models` vision server instead
   of a paid API.

## Decision (Tristan, 2026-08-30)

- Peekaboo is agent-lane only. Evaluate it beside `cua-driver` and
  `dscomputer`. No architecture from it enters Quick Launch.
- **Take as Type to Click candidates:** Dock items as targets, and system
  dialog targets (permission prompts, other apps' alerts). Note: those live
  in other processes, so the scan would need a second pid or the system-wide
  element; small, separate design step.
- **Not taken, window controls:** the Windows catalog already owns layouts,
  and the focused window's own buttons are already ordinary scanned targets.
- **Rejected, scroll-to-visible before click:** badges only mark visible
  controls, a human types what they can see, and closed-menu commands already
  activate semantically without coordinates. An agent-lane concern.
- **Stays rejected, hint codes:** search-only remains the design.

## Bottom line

Same sensing substrate, opposite brain. Peekaboo is what this substrate
becomes when the consumer is a model; Type to Click is what it becomes when
the consumer is a person. They complement rather than compete. The one thing
the search-only design buys that Peekaboo's IDs do not: every target is
speakable, which is why voice targeting is saved as a future task
(see the 2026-08-30 addendum in `launcher-roadmap-20260822.md`).
