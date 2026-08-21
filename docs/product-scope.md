# Product scope

apfel-quick is a keyboard-first launcher for seven jobs:

1. Launch apps.
2. Find and paste snippets.
3. Find and paste recent clipboard items.
4. Translate selected or typed text.
5. Open saved links.
6. Run quick AI actions.
7. Move and resize windows.

It does not need file search, screen history, OCR, or a full chat workspace.

## Interaction contract

The app stays running as a small menu-bar process.

- The main global hotkey opens one search field.
- Typing filters items across the enabled catalogs.
- An alias narrows directly to an item or command.
- Return runs the default action.
- Command-K shows other actions for the selected item.
- Any item or command can have its own global hotkey.
- A direct global hotkey runs without opening the search panel when no choice or result is required.
- A result that needs review opens in the panel. The input regains focus when the result finishes.

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
