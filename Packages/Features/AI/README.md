# AI

Ask a model from the launcher, with a provider the user chooses. Nothing is sent anywhere until the user runs an AI command.

## Providers

| Provider | How | Where requests go |
|---|---|---|
| Apple on-device model, the default | `OnDeviceModelService`, a service the feature owns. The live one wraps FoundationModels; scenarios and self-tests get a simulated one | nowhere |
| Anthropic | Messages API, `POST /v1/messages` with `stream: true`, read as server-sent events through Kit's HTTP service. The key is a Kit secret | api.anthropic.com |
| OpenAI-compatible server | `POST <base address>/chat/completions` with `stream: true`, an optional bearer key | the base address's host |

All three sit behind `ModelProvider`, which streams `ModelEvent`s. `ProviderResolver` makes the one the settings choose when an answer starts, and reads a key only then.

Anthropic requests send `anthropic-version: 2026-10-21`, no sampling parameters and no thinking setting, so each model thinks as it does by default. Opus, Sonnet and Fable requests also send `fallbacks: "default"` with the `server-side-fallback-2026-07-01` beta, so a declined request is answered by the model the API picks, in the same stream. Thinking blocks come back with their signatures and are sent back unchanged with the next turn. The system prompt is kept with each conversation, so the history the API checks never changes.

## What it declares

| Kind | What |
|---|---|
| Command `ask` | Ask AI. Takes the root query on Tab, and is a fallback: Ask AI about the typed text. With nothing typed it opens an empty page whose field takes the first question |
| Command `chat` | AI Chat: kept conversations by day, with Open, New, Rename, Export as Markdown, Delete and Delete All |
| Command `new-chat` | New AI Chat |
| Commands `improve-writing`, `fix-spelling-and-grammar`, `make-shorter`, `make-longer`, `change-tone`, `summarize`, `explain`, `translate` | Commands on the selected text. Change Tone takes a tone, Translate with AI a language |
| Command `create-command` | Create AI Command: a name and a prompt in Kit's templates |
| Commands `custom.<slug>-<hash>` | The user's own commands, with Edit and Delete on their rows |
| Command `setup` | Set Up AI Provider |
| Universal actions | The eight commands, Change Tone as a submenu of tones, and the user's commands that use `{selection}` |
| Settings pane | provider, Anthropic key and model, server address, model and key, system prompt, response length, translation language, how long to keep chats, which asks first when a shorter time deletes chats, Delete All Chats, Accessibility |
| Status | shown in settings when `commands.json` cannot be read, or was written by a newer version |
| Permission | Accessibility, to read the selection and to paste results |

## Answer pages

`AnswerSession` is the detail source for Ask AI, the commands on text and AI Chat. It streams the answer in a detached task, takes follow-ups, and offers Copy Answer, Paste Answer, Copy Last Code Block, Regenerate, Stop and Continue in Chat. A command on text offers Replace Selection, or Paste Result when the text did not come from a selection, and Copy Result. An answer that ends early keeps what arrived and ends with a note that says what to do.

## Storage

- `Chats/<id>.json` in the feature's data folder, one file per kept chat. Each file's modification date is the chat's last change, so pruning reads only the folder listing.
- `commands.json` in the same folder: the user's own commands. Their prompts are parsed once, off the main thread, when the file is read or saved. A file that cannot be read, or one from a newer version, is never overwritten, and settings says so.
- Keys in the Keychain through Kit's secret service.

Ask AI and the commands on text keep nothing unless the user chooses Continue in Chat. A kept chat whose last question has no answer is not sent when it is opened; Regenerate sends it.

## Deep links

A deep link never reads the selection or the clipboard and never sends anything by itself. Ask AI, the commands on text and the user's commands open a form with the text, and send only when the user presses Send.

## Tests

`scripts/swiftpm.sh Packages/Features/AI test`. Both HTTP providers run against Kit's `FakeHTTP` with event streams written by hand from the documented formats, and against a byte-level service to split characters across chunks. The on-device model is a test double. `AI_BENCHMARK=1` with a release build runs the benchmarks.
