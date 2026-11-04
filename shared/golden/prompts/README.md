# Golden chat-prompt fixture

`prompts.json` records what the Flutter chat screen sends a backend for a
fixed set of questions: the system prompt, the prompt with the sources in it,
and the citations those sources become, including the exact JSON both apps
store for them in `council_user.db` (`conversation_messages.citations`). The
prompt building lives in `lib/src/services/inference/chat_prompt.dart`
(`ChatPrompt`, moved out of `chat_screen.dart` unchanged). The SwiftUI app in
`apple/` ports it to `CouncilCore/Inference/ChatPrompt.swift` and
`Citation.swift`, and has to reproduce this file exactly
(`ChatPromptGoldenTests`). The Flutter side is held to it by
`test/chat_prompt_golden_test.dart`, which writes it and runs in the ordinary
`flutter test` suite.

Exactness matters for two reasons. A conversation carried from one app to the
other (apple/PLAN.md, Phase 7) reads its stored citations back, so the JSON is
a storage format. And the prompt is the input a model answers from: if the two
apps cut a passage at different places or word the instruction differently,
the same question gets different answers depending on the device.

Never edit `prompts.json` by hand.

## Regenerating and verifying

```sh
flutter test test/chat_prompt_golden_test.dart                                   # verify
flutter test test/chat_prompt_golden_test.dart --dart-define=UPDATE_GOLDENS=true # rewrite
```

Use the CI-pinned Flutter (`~/development/flutter-3.44.8/bin/flutter`). Its
`pub get` rewrites `pubspec.lock`; restore that with `git checkout pubspec.lock`
before committing.

The cases, inputs included, are defined in the Dart test. To add one, add it
to `_cases()` there and run the update. Verification checks each case field by
field and then that the file is byte for byte what the cases produce, so a case
removed from the code but left in the file fails too. After an intended change
to the prompt, regenerate; the Swift port then has to follow.

## Format

| Field | Meaning |
|---|---|
| `comment` | Where the file comes from. |
| `system` | `ChatPrompt.systemPrompt` (Dart's `OllamaService.buildSystemPrompt`). |
| `cases` | One record per question. |

Each case:

| Field | Meaning |
|---|---|
| `id`, `why` | A name, and what the case covers. |
| `question` | The question as passed to `ChatPrompt.build` (the screen has already trimmed what was typed; the cases don't always, on purpose). |
| `contextBudgetChars` | The backend's budget: 0 (search-only), 4000 (Foundation Models), 12000 (Ollama), 60000 (cloud), and some in between. |
| `pinned` | The passage the reader selected (`contentUnitId`, `quote`, `reference`, `sourceTitle`), or null. |
| `retrieved` | What `searchForRAG` returned, only the columns the prompt reads: `id`, `content`, `source_title`, `source_author`, `tradition`, `source_url`. The Swift test turns each into a `ContentUnitRow`. |
| `perPassage` | Each passage's share of the budget, `floor(budget / count)` clamped to 400–8000. |
| `prompt` | The prompt, as a backend receives it (see below). |
| `citations` | `Citation.toJson()` for each source, in prompt order: `citations[0]` is source [1]. |
| `citationsJson` | `jsonEncode(citations)`: the exact text stored in `conversation_messages.citations`. |
| `traceable` | `Citation.isTraceable` for each. |

Invisible characters (control characters, no-break and other spaces, combining
marks, U+FEFF, and U+FFFD) are written as JSON escapes so the file can be read
and diffed. They decode to the same strings.

## Lone surrogates

A passage longer than its share is cut at that many UTF-16 code units. When the
cut falls between the two halves of a character outside the BMP (case
`cut-splits-surrogate-pair`), Dart's string keeps a lone high surrogate. Every
backend receives the prompt UTF-8 encoded, which turns it into U+FFFD, so the
fixture records the prompt in that form, and the Dart test compares it after
the same round trip. A Swift `String` can't hold a lone surrogate, and
decoding the cut code units produces U+FFFD directly, so the two apps agree on
what is actually sent.

## Quirks recorded as Dart behaves

- `pinned-nothing-to-name`: a pinned passage with neither title nor reference
  gives the anchor sentence "The reader is reading , quoted as source [1]".
- `pinned-empty-source-title`: an empty (not missing) title is used as the
  citation's `source` as it is, because `??` only replaces null; the anchor
  label leaves it out.
