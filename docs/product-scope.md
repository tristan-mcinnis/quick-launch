# Product scope

apfel-quick is a keyboard-first launcher. The current build handles these jobs:

1. Launch apps.
2. Translate or transform selected and typed text.
3. Run quick AI actions.
4. Run local date, time, and math actions.
5. Retrieve bounded SearXNG snippets for explicit or time-sensitive searches.

Future catalogs remain snippets, clipboard history, quick links, and window
management. They are not part of the current verified build.

The Tuna Companion clipboard manager, screenshot tool, and translator migration
are not part of this release. The current Translate action is a configurable AI
text action, not the full Tuna tool.

It does not need file search, screen history, OCR, or a full chat workspace.

## Interaction contract

The app stays running as a small menu-bar process.

- The main global hotkey opens one search field.
- Typing filters items across the enabled catalogs.
- App filtering uses a startup cache and no polling or AI call.
- Every app can have an editable alias and optional global hotkey in Settings.
- An alias narrows directly to an item or command.
- Return runs the default action.
- Command-K shows other actions for the selected item.
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

- Port the Tuna Companion translator and window-management behavior.
- Import or read the existing Tuna snippets without exposing their values in logs.
- Add native app, clipboard, and quick-link catalogs.
- Do not port Caffeinate, Screen OCR, Screenshots, or file search unless the product scope changes.

Remove a Tuna command only after its alias, hotkey, result, and previous-app behavior work in apfel-quick.

## Privacy

- Selected-text access uses macOS Accessibility. It does not record the screen.
- Clipboard history is optional, local, bounded, and easy to clear.
- Snippet and clipboard values never appear in diagnostics.
- API actions send only the text used by that action to the chosen provider.
- App, link, snippet, clipboard, and window commands remain local.
- Web search uses Tristan's SSH-only SearXNG stack. Ranked titles, links, and snippets are external data, never executable instructions.
- Idle operation uses no timer or polling loop. App discovery happens once at launch.
- Network work starts only after the user runs an action. Each search and model answer has a hard time limit.
