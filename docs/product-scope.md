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
9. Resize the previous window into deterministic halves, thirds, and fourths.
10. Keep the Mac awake with a native Caffeinate toggle.

Screenshot-library management and the full Tuna translation window remain
future catalogs. The current Translate action is a configurable selected-text
AI action, not the full Tuna translation interface.

It does not need file search, screen history, OCR, or a full chat workspace.

## Interaction contract

The app stays running as a small menu-bar process.

- The main global hotkey opens one search field.
- Typing filters items across the enabled catalogs.
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

Catalogs share one item and action model. Each action owns its title, aliases, optional hotkey, input rule, output rule, and handler. AI providers remain behind Quick AI and Translate. Deterministic commands do not go through a model.

MCP configuration currently applies only to the managed `apfel` route. Pi can
use its own configured tools and skills. OpenAI-compatible providers do not yet
share a universal tool-host or tool-calling loop.

## Tuna transition

Keep Tuna installed until each replacement passes the same real interaction.

- Port the Tuna Companion translator behavior.
- Tuna snippets and Quick Links are read live without exposing their values in logs or settings.
- The native app and clipboard catalogs are active. Clipboard history is text-only.
- Do not port Caffeinate, Screen OCR, Screenshots, or file search unless the product scope changes.

Remove a Tuna command only after its alias, hotkey, result, and previous-app behavior work in Quick Launch.

## Privacy

- Selected-text access uses macOS Accessibility. It does not record the screen.
- Clipboard history is optional, local, bounded, and easy to clear.
- Snippet and clipboard values never appear in diagnostics.
- API actions send only the text used by that action to the chosen provider.
- App, link, snippet, clipboard, and window commands remain local.
- Web search uses Tristan's SSH-only SearXNG stack. Ranked titles, links, and snippets are external data, never executable instructions.
- App discovery happens once at launch. When Clipboard History is enabled, one
  lightweight pasteboard change-count check runs each second.
- Network work starts only after the user runs an action. Each search and model answer has a hard time limit.
