# Raycast core AI procedures, from official documentation

Retrieved 2026-10-21. Sources: the official Raycast Manual (manual.raycast.com), eleven pages, listed at the end. Every statement below is a **documented claim**. Nothing here is observed behaviour: no app was launched and no account was used. Where the manual is silent, the item appears under Unknowns rather than being inferred.

Availability note: Raycast AI features are marked Pro Exclusive in the manual, and the AI pages assume a signed-in paid account. That is recorded here only as a precondition for any later head-to-head test, not as a product advantage.

## 1. Entry points

- **Quick AI** is a one-off answer inside Root Search. Three documented entries: type the question in Root Search and press `Tab` (Raycast submits it immediately); run the Quick AI command for an empty prompt; or set Quick AI as a fallback command under Settings → Launcher → Fallback Commands so unmatched Root Search text plus `↵` goes to AI. `Tab` opens Quick AI even with no text. [1]
- **AI Chat** is a separate window. Enter it from Root Search with the AI Chat command, or from a Quick AI answer with `⌘J`. [2]
- **Global hotkey**: any command, including these, can take a custom global hotkey. [4]
- **Screen capture entry**: Send Focused Window to AI first runs a setup step, then works from one hotkey. The suggested default is a double tap of the right `⌘`, and Raycast refuses to overwrite a hotkey another command already owns. [8]

## 2. Ask, follow up, promote

- Quick AI: type, `↵` to submit, answer streams in the same window. Typing again after the answer continues the same conversation; it is documented as a full conversation, not single-shot. [1]
- Quick AI navigation during that conversation: `⌘R` regenerate with the same model, `⇧⌘R` regenerate with a different model, `⌘N` new conversation, `⌘[` / `⌘]` move between recent Quick AI chats. [1]
- **Promotion**: `⌘J` moves the Quick AI conversation into AI Chat, carrying history, model and attachments. [1][2]
- AI Chat: `↵` sends, `⇧↵` adds a line. While a response streams, a new message is either **Queued** (runs after the current one) or **Steered** (injected into the running turn). Queue is the documented default; `⌘↵` applies the other behaviour once, or `⌥↵` when `⌘↵` is the primary send shortcut. [2]
- Auto-new-chat: Quick AI starts fresh after an inactivity timeout set in Settings → AI → Chat → Start New Chat; documented options are 5, 10, 15 and 30 minutes, 1 hour, always, never. The same timer decides whether a Send to AI command reuses the active chat. [1][2]

## 3. Selected text, named inputs, insertion

- **AI Commands** are saved prompts run from Root Search. The documented pattern: select text in any app, open Raycast, run the command. Most commands act on the active app's selection or focused field. [3]
- Prompt inputs: `{selection}` for highlighted text, `@` for an AI Extension, `{` for a placeholder. `{argument}` prompts for a value in the search bar, and the documented maximum is **3 different arguments** per command. `{argument name="tone" options="happy, sad, professional"}` gives fixed choices; `{argument default="..."}` makes it optional. [3][7]
- Other documented placeholders for AI Commands: `{clipboard}` (with `offset=1` for the second-newest entry), `{calculator}`, `{browser-tab}` (Markdown, text or HTML, plus a CSS selector), `{date}` / `{time}` / `{datetime}` / `{day}` with `offset`, `format` and `locale`. Modifiers chain with `|`, and `raw` opts out of Raycast's default wrapping of placeholder values in triple quotes for AI Commands. [7]
- **Insertion**: a command's Output Behavior is either **Open in Raycast** (result in a window, then copy, paste or continue in chat) or **Replace Selection** (written back over the selected text). "Highlight Editing Changes" marks what changed in place. [3]
- **Quick Fix** is the one-hotkey variant of Fix Spelling and Grammar: press it in any focused app and the text is replaced in place. Documented extras: default hotkey is a double press of the right Shift; "Prefer Selection" limits it to the selection rather than the whole field; "Preserve Formatting" is experimental and documented only for apps it supports. It requires macOS Accessibility permission and, per the manual, always runs on Raycast AI and spends credits whichever provider other commands use. [3]
- Command management: `⌘↵` saves, `⌘E` edits, `⌘D` duplicates, plus Share and JSON import. Each command stores its own model and there is documented to be no per-command "use default". [3]

## 4. Context, files, links, images

- Attach by clicking the composer's attach control or typing `@`. Documented sources in AI Chat: files from disk (documents, code, images), Raycast Notes, clipboard history, open browser tabs, web search results, focused window, selected text, a chosen window, a dragged screen area or the whole screen, and today's or upcoming calendar events. Quick AI supports the narrower set: focused window, selected text, screen area or entire screen. [1][2]
- Attachments are scoped to the message they are sent with, and the model may refer back to them later in the chat. They travel with a Quick AI conversation promoted to AI Chat. [1][2]
- **Oversize handling**: when a tool result or attachment exceeds the context window, Raycast writes the full content to a file and gives the model the beginning plus the path. Documented as automatic, with nothing to configure. [2]
- Long conversations are summarised in the background rather than cut off, shown as a "Summarizing chat…" step that settles to "Summarized chat". [2]
- Screen Awareness capture bundles app name and window title, readable window text from the accessibility layer, the selection, the focused control and value, a window screenshot, browser tab title/URL/content when the Browser Companion is installed, and selected Finder file paths. Secure and password controls are excluded from the text context. Raycast excludes its own windows, captures only on request, and stores nothing. [8]
- Privacy of attachments: images are uploaded to Raycast's servers by default whichever model is used; deleting the message or chat deletes them. When Cloud Sync is off or AI Chat history is not synced, images sent to a local model, an extension model or a connected subscription stay on device, but Custom Provider images are still uploaded. [11]

## 5. Model choice, local, bring-your-own

- Defaults are set per surface under Settings → AI → Models & Providers → Default Models: Quick AI, AI Chat (including "Last Used Model"), and Custom AI Commands. Models can be hidden from every picker, grouped by provider, sorted by brand, name, speed, intelligence or context window. [1][2]
- **Auto** picks a model per request from a Model Preference of Lightweight, Balanced or Flagship, and each surface keeps its own preference. Follow-ups stay on the same model where possible. [2]
- **Local**: Ollama only. Install or point at a model in Settings → AI → Models & Providers → Local Models, or use `ollama pull` and Sync Models; Raycast starts the Ollama server itself. A remote Ollama host can be entered as a field. Local models work in Quick AI, AI Chat and AI Commands, and advertised vision or tool support is read from Ollama. Local models do not power the Extension AI API or Emoji Search. [5]
- **BYOK**: one API key each for Anthropic, Google, OpenAI and OpenRouter, added under Settings → AI → Models & Providers → API Keys with a Verify step. For the first three, only models already in Raycast AI are reachable; an OpenRouter key reaches its full catalogue. Requests for the first three are documented to pass through Raycast's servers; OpenRouter goes direct. Image generation still uses Raycast AI credits. [6]
- **Custom Providers**: a `providers.yaml` at `~/.config/raycast/ai/providers.yaml` lists providers (id, name, OpenAI-compatible `base_url`, optional `api_keys`, `models`). Per model: id, name, `context` window, and ability flags for temperature, vision, system message, tools and reasoning effort. Tool use is opt-in per file. Image generation is not available for these models. [9]

## 6. Cancel, retry, history, keyboard paths

- **Cancel**: the manual documents only that an empty composer plus send cancels the running response; no dedicated stop key is documented. [2]
- **Retry**: `⌘R` regenerates the last response, `⇧⌘R` regenerates on another model, and after a credit stop the documented recovery is to top up or switch model, then choose Try Again. Editing an earlier message re-runs from that point and replaces what followed. [1][2][10]
- **History**: sidebar with `⇧⌘S` or `⌘B`, chat search `⇧⌘F`, jump to the first ten chats with `⌘1`–`⌘0`. Chats can be pinned, archived, deleted, renamed, copied as text, or branched (`⇧⌘B`). Delete-all-unpinned is `⌃⇧X`. Deleted chats sit in Recently Deleted for **60 days**; auto-archive period is a setting. Quick AI and AI Chat histories can be shown combined or separate. [2][4]
- **Other documented keys**: `⇧⌘A` attach, `⌘F` find in chat, `⌘J` send selected item to AI Chat, `⇧⌘M` change model, `⇧⌘Y` creativity, `⇧⌘U` reasoning effort, `⌃M` dictation start/accept, `Esc` cancel dictation. With an empty composer `↑` loads and walks back through your messages, and `Esc` restores the draft. [2][4]
- Background completion notifications are off by default and, on macOS, need system notification permission. [2]

## 7. Documented numeric limits

| Limit | Value | Source |
| --- | --- | --- |
| Arguments per command | 3 | [3][7] |
| Long messages collapsed | over 10 lines | [1][2] |
| Recently Deleted retention | 60 days | [2] |
| Quick AI / chat inactivity reset | 5, 10, 15, 30 min, 1 h, always, never | [1] |
| Custom tool web search timeout | 30 s | [9] |
| Custom tool search snippet cap | 2,000 characters | [9] |
| Custom tool read_page timeout | 60 s | [9] |
| Custom tool page content cap | 200 KB, marked truncated | [9] |
| web_search results | default 10, range 1–20 | [9] |
| Context window | per model, set in `context`; shown in Manage Models | [2][9] |

## 8. Unknowns (not documented on these pages)

1. No numeric limit for attachment file size, file count, or images per message. Only the qualitative oversize-to-file behaviour is documented.
2. No documented stop/abort shortcut for a streaming AI Chat response beyond sending on an empty composer.
3. No documented retry-after-failure button name other than Try Again after credit exhaustion.
4. No documented mapping from Auto's Lightweight/Balanced/Flagship to concrete model names, and no published context-window figure per model on the manual pages used.
5. Whether AI Commands accept image or file input as well as text selection.
6. Default chat-retention and default auto-archive period, which are described as settings without a stated default.
7. Local model sizes, hardware floors and token throughput are not stated.
8. Response latency figures are absent; the only speed statements are relative marketing comparisons inside the manual.

## Sources

1. Quick AI — https://manual.raycast.com/ai/quick-ai
2. AI Chat — https://manual.raycast.com/ai/ai-chat
3. AI Commands — https://manual.raycast.com/ai/ai-commands
4. Keyboard Shortcuts — https://manual.raycast.com/keyboard-shortcuts
5. Local Models — https://manual.raycast.com/ai/local-models
6. Bring Your Own Key — https://manual.raycast.com/ai/bring-your-own-key
7. Dynamic Placeholders — https://manual.raycast.com/dynamic-placeholders
8. Screen Awareness — https://manual.raycast.com/ai/screen-awareness
9. Custom Providers — https://manual.raycast.com/ai/custom-providers
10. AI Credits — https://manual.raycast.com/ai/ai-credits
11. Raycast AI Privacy & Security — https://manual.raycast.com/ai/raycast-ai-privacy-security

Sanitised summary. No verbatim vendor text, no vendor code, no account data, no screenshots. Raw page captures are kept outside Git.
