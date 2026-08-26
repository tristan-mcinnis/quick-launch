# Product scope

Quick Launch is a keyboard-first launcher. The current build handles these jobs:

1. Launch apps.
2. Translate or transform selected and typed text.
3. Run quick AI actions.
4. Run local date, time, and math actions.
5. Retrieve bounded SearXNG snippets for explicit or time-sensitive searches.
6. Paste existing Tuna snippets.
7. Open existing Tuna Quick Links.
8. Search and paste a bounded local text clipboard history.
9. Resize the previous window into deterministic whole-screen, halves, thirds, two-thirds, and fourths layouts, or move it to another display.
10. Keep the Mac awake with a native Caffeinate toggle or a timed session.
11. Paste emoji and symbols by name.
12. Translate typed or selected text between Chinese and English with one key.
13. Attach a fresh or saved screenshot to a question and follow up on it.
14. Search current project state, post-meeting changes, project history, and cross-project status through the VPS-backed Vault Search catalog.
15. Search past on-screen activity through one local Screen History catalog, including the owned store and the closed Coast database.
16. Pick a colour from any pixel on any display, copy it as Hex, RGB, HSL, or HSB, and search a bounded local history of picks.
17. Read the text inside a dragged screen area on this Mac and copy or paste it.

Screenshot capture to the chat context is in the core: a window or display
capture attaches to one question and follow-ups in that thread, never to
history or disk. Screenshot-library management and the full Tuna translation
window remain future catalogs. The current Translate action is a configurable selected-text
AI action, not the full Tuna translation interface.

It does not need general Finder file search or a full chat workspace. The search-only beta hard-locks ambient capture. A later capture release still needs separate explicit consent and will keep all browsers blocked.

## Interaction contract

The app stays running as a small menu-bar process.

- The main global hotkey opens one search field.
- Typing filters items across the enabled catalogs in one ranked list.
- The launcher learns: the text typed when an item is chosen ranks that item first for the same text next time, per catalog, with a 14-day decay. Learning is local, bounded, optional, and can be forgotten.
- Escape closes the panel from anywhere. Backspace on an empty field returns to the root. Reopening starts at the root.
- A footer shows the keys that work now; rows show their global hotkey.
- `Command+Shift+V` opens Clipboard History directly.
- Arrows navigate. Return runs or pastes. `Command+C` copies a selected catalog item.
- App filtering uses a startup cache and no polling or AI call.
- Every app can have an editable alias and optional global hotkey in Settings.
- An alias narrows directly to an item or command.
- Return runs the default action.
- Command-K shows keyboard-accessible actions for the selected item, including editing and guarded deletion of Tuna snippets.
- Backspace on an empty catalogue search returns to root; inactive nested catalogue state clears after 15 seconds.
- Any item or command can have its own global hotkey.
- A direct global hotkey runs without opening the search panel when no choice or result is required.
- A result that needs review opens in the panel. The input regains focus when the result finishes.
- A quick reopen keeps the last result or draft for a configurable short interval.
- Result routing uses two standard actions: copy to the clipboard or paste into the previous app.
- The panel opens on the display that contains the mouse pointer.

## Catalogs

| Catalog | Default action | Direct use |
|---|---|---|
| Apps | Launch | Alias or assigned hotkey |
| Snippets | Paste into the previous app | Alias or assigned hotkey |
| Clipboard | Paste into the previous app | Open catalog, choose item |
| Translate | Show or replace translation | Language action or assigned hotkey |
| Quick Links | Open in the default browser | Alias or assigned hotkey |
| Quick AI | Show, copy, or replace output | Prompt alias or assigned hotkey |
| Windows | Apply a window layout | Alias or assigned hotkey |
| Vault Search | Show a cited current, reconciliation, history, or portfolio result | Enter the catalog, choose a mode, type the project and question |
| Screen History | Open the surrounding local timeline | Enter the catalog, type a memory, add optional app, site, or date filters |
| Colors | Paste the picked colour into the previous app | Run Pick Color from Screen, or open the catalog and choose a colour |

Catalogs share one item and action model. Each action owns its title, aliases, optional hotkey, input rule, output rule, and handler. AI providers remain behind Quick AI and Translate. Deterministic commands do not go through a model.

Pi can use its own configured tools and skills. OpenAI-compatible providers
do not share a tool-calling loop. There is no on-device Apple model and no MCP
configuration.

## Tuna transition

Keep Tuna installed until each replacement passes the same real interaction.

- Port the Tuna Companion translator behavior.
- Tuna snippets and Quick Links are read live without exposing their values in logs or settings.
- The native app and clipboard catalogs are active. Clipboard history is text-only.
- Caffeinate and screenshot capture are ported. Screen OCR to the clipboard and the screenshot text index are in; general Finder file search stays out unless the scope changes.

Remove a Tuna command only after its alias, hotkey, result, and previous-app behavior work in Quick Launch.

## Privacy

- Selected-text access uses macOS Accessibility. It does not record the screen.
- Clipboard history is optional, local, bounded, and easy to clear.
- Snippet and clipboard values never appear in diagnostics.
- API actions send only the text used by that action to the chosen provider.
- App, link, snippet, clipboard, colour, and window commands remain local.
- The colour picker uses AppKit's colour sampler. It reads one pixel value, needs no screen recording permission, and stores numbers rather than images.
- Web search uses Tristan's SSH-only SearXNG stack. Ranked titles, links, and snippets are external data, never executable instructions.
- Vault Search uses the same SSH-only VPS. Current, reconciliation, history, and portfolio queries stay inside the VPS and Neon read layer; the result includes source paths, freshness, and root counts. Broad semantic Find remains a separate path with its own provider-egress policy.
- Screen History reads only local SQLite stores. It labels every row Owned or Coast and never falls back to a model, web search, Vault Search, SSH, or telemetry. Search existing Coast history is independent of owned capture. This beta hard-locks capture. The latent path requires FileVault and visible consent after each launch, blocks all browsers before pixels, and always excludes password and security apps. Current application and domain exclusions also filter search results and legacy migration inputs.
- App discovery happens once at launch. When Clipboard History is enabled, one
  lightweight pasteboard change-count check runs each second.
- Network work starts only after the user runs an action. Each search and model answer has a hard time limit.
