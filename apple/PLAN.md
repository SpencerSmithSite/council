# Council for Apple platforms — native SwiftUI plan

Started 2026-11-02. The Flutter app keeps Android, Windows and Linux. This
folder becomes the iPhone, iPad and Mac app, written in SwiftUI so that Liquid
Glass is the real system material rather than the `GlassSurface` approximation
described in PLAN.md Phase 23. Flutter draws every pixel itself and can't get
closer than that approximation, so the Apple app moves to SwiftUI. The rest of
the app stays shared.

## Decisions

| Question | Decision | Why |
|---|---|---|
| Platforms | iPhone, iPad and Mac together, one multiplatform SwiftUI target | One codebase; the Mac is not a later port |
| Minimum OS | iOS, iPadOS and macOS 26 | Liquid Glass and Foundation Models both start there; no fallback look to maintain |
| When it replaces Flutter | At full feature parity, TestFlight until then | Existing users must not lose features or data on update |
| Mac distribution | Developer ID DMG, now notarised, with an in-app updater | Unchanged channel; no sandbox or App Review |
| Shared logic | Rewritten in Swift, held to the Flutter app by golden tests | No third language in the build; drift is caught in CI |
| Downloaded local model | MLX (`mlx-swift`) with MLX builds of Qwen3 0.6B / 1.7B | Apple's own Metal framework, fastest on Apple silicon |
| Themes | The whole catalogue, every theme the Flutter app offers | Readers keep the theme they chose |
| Reader | Continuous scroll, Books-style reading controls | Keeps jump-to-search-hit simple |
| Bundle ID | `site.spencersmith.council`, the same as today | Ships as an update to the existing "Council" listing and keeps the data container |

Not in scope: pre-26 support; any shared Rust/C core; changes to the Flutter
app beyond the small shared-fixture work below and removing `ios/` and `macos/`
once this ships.

## Repo layout

```
apple/
  Council.xcodeproj
  Council/            app target: iOS, iPadOS, macOS
    App/              scenes, navigation, commands (Mac menus)
    Features/         Read, Browse, Search, Chat, Notes, Bookmarks, Settings, Onboarding
    DesignSystem/     theme palettes, reading typography, glass usage rules
  CouncilCore/        local Swift package: no UI, fully unit-tested
    Corpus/           SQLite access, FTS5, corpus version stamp
    Packs/            catalogue, manifest, download, checksum, merge
    Search/           WordPiece tokenizer, query encoder, vector index,
                      entity recogniser, hybrid ranker
    Inference/        backends: Foundation Models, MLX, Ollama, cloud
    UserData/         highlights, notes, conversations, bookmarks, shelf
    Updates/          release manifest, Mac installer
    Migration/        one-time import of the Flutter app's data
shared/
  golden/             search fixtures both apps are tested against
  themes.json         theme palettes, read by both apps
```

## Technical choices

- **UI:** SwiftUI with `@Observable` models and Swift concurrency. Use the
  standard building blocks everywhere (`TabView` with `.sidebarAdaptable`,
  `NavigationSplitView`, `.toolbar`, `.searchable`, `.sheet`, `Menu`), and add
  custom `.glassEffect()` only where no standard component fits. Never put
  glass behind body text.
- **SQLite:** GRDB.swift on the system SQLite, which already includes FTS5 on
  Apple platforms. The same files are read as today: the seed corpus,
  `theology.db`, the `packs/` workspace and `council_user.db`.
- **Query encoder:** ONNX Runtime's Swift package running the *same*
  `model_quantized.onnx` (all-MiniLM-L6-v2, 384 dims) used by the Flutter app
  and `tools/build_embeddings.py`. Same file, same vectors. A Core ML conversion
  might be more "native", but it risks small numeric differences against an
  index built with ONNX, so it isn't worth it.
- **Local model:** `mlx-swift` / MLXLLM. Models come from `mlx-community`
  4-bit Qwen3 builds, with a memory check equivalent to `device_memory.dart`
  before offering the 1.7B model.
- **Foundation Models:** called directly, replacing the `FoundationModelsBridge`
  method channel.
- **Chat Markdown:** a block-level SwiftUI Markdown renderer, chosen in
  Phase 5. `AttributedString(markdown:)` only handles inline formatting.
- **Secrets:** Keychain via Security.framework.

## Themes with real glass

Liquid Glass picks up colour from whatever is underneath it, so it stays
authentic on a custom palette. Each catalogue theme supplies a background,
surface, text and accent colour. Glass bars float over those backgrounds and
pick up their colour; the accent is applied with `.tint()`. The "System"
choice uses Apple's semantic colours and is the default.

To keep one source of truth, move the palettes out of
`lib/src/theme/themes.dart` into `shared/themes.json`, read by both apps. If
changing the Flutter side isn't wanted, generate a Swift file from
`themes.dart` instead, with a test that checks the theme ids match.

## Phases

### Phase 0 — Groundwork
- [ ] Create `apple/Council.xcodeproj` (multiplatform app, deployment target
      26, the existing bundle ID and team Y2Q5JVG8X5) and the `CouncilCore`
      local package.
- [ ] Golden fixtures. A Flutter integration test runs a fixed query set (by
      reference, keyword, semantic, entity, and mixed) and writes
      `shared/golden/search.json` with the ranked ids. The same test then
      asserts against that file, so a Flutter ranking change has to update the
      fixture deliberately.
- [ ] Fixtures for the pack format: a small pack, its manifest, and the
      expected merged result, including an `idSpace` bump.
- [ ] CI: a macOS job that builds `apple/` and runs the `CouncilCore` tests
      against the golden fixtures.

### Phase 1 — CouncilCore: corpus, packs, search
- [ ] Open the seed corpus and the corpus version stamp just as
      `database_service.dart` does.
- [ ] Packs: catalogue, manifest, download, checksum verification, merge.
      Follow the positional-`INSERT … SELECT *` rule and the `reshaped` /
      `idSpace` handling exactly as `build_packs.py` and `pack_service.dart`
      define them.
- [ ] WordPiece tokenizer, query encoder, vector index, entity recogniser,
      hybrid ranker.
- [ ] Gate: every golden query returns the same ranked ids as Flutter.

### Phase 2 — App shell and design system
- [ ] Top-level navigation with the same sections as the Flutter app: a tab
      bar on iPhone that becomes a sidebar on iPad and Mac
      (`.sidebarAdaptable`), and the tab bar shrinking on scroll.
- [ ] Theme system from `shared/themes.json`, a theme picker with live
      previews, and dark/light variants where a theme has them.
- [ ] Check the system accessibility settings in every theme: Reduce
      Transparency, Increase Contrast, Dynamic Type and Reduce Motion.

### Phase 3 — Reading
- [ ] Passage reader: continuous scroll, segments, the passage action bar
      rebuilt as a glass toolbar and context menu.
- [ ] Books-style reading sheet: font, size, line spacing, margins, theme.
- [ ] Highlights, notes and note editor, bookmarks, read shelf, browse,
      content detail, source reader.

### Phase 4 — Search
- [ ] `.searchable` with a search-role tab, results grouped by source, and
      jumping to the hit inside the reader.

### Phase 5 — AI
- [ ] Backends: Foundation Models, MLX local model (download, progress,
      storage, delete), Ollama on the local network
      (`NSLocalNetworkUsageDescription`), and cloud (Anthropic, OpenAI,
      Gemini, xAI) with keys in Keychain.
- [ ] Streaming, the reasoning filter, citations into the reader, chat
      history.
- [ ] The AI backend screen: availability states matching
      `PlatformLlmState`, including the "Apple Intelligence is off" hint.

### Phase 6 — Settings, onboarding, updates
- [ ] Settings, onboarding, update check against the existing `updates.json`.
- [ ] Mac: port the `_macos` path of `update_installer.dart` (download DMG,
      verify, replace, relaunch).

### Phase 7 — Migration from the Flutter install
The native app installs over the Flutter one with the same bundle ID, so the
data is still on the device. The new app just has to read it.
- [ ] `council_user.db`, the corpus and `packs/` in Application Support: open
      them in place (same schema).
- [ ] `shared_preferences`: on Apple platforms it stores keys in
      `UserDefaults.standard` with a `flutter.` prefix. Map theme, font size,
      citations, auto-update, bookmarks and shelf keys to the new settings,
      then mark migration done.
- [ ] Keychain: read cloud keys from `flutter_secure_storage`'s default
      service and re-save them under the app's own service.
- [ ] Downloaded `.litertlm` models: MLX can't use them. Delete them to free
      the space and offer the MLX download.
- [ ] Test it for real: install the current Flutter build, create highlights,
      notes, chats, bookmarks, a theme choice and a cloud key, then install the
      native build over it on iPhone, iPad and Mac.

### Phase 8 — Mac specifics
- [ ] Menu commands and keyboard shortcuts, a Settings scene, multiple windows
      where it makes sense, toolbar customisation.
- [ ] Release script: archive, Developer ID sign, notarise with `notarytool`,
      staple, DMG. This replaces the hand re-signing step in today's release
      process.

### Phase 9 — Parity and ship
- [ ] Parity checklist against `lib/src/screens/`: AI backend, bookmarks,
      browse, chat history, chat, content detail, note editor, notes,
      onboarding, read, settings, source reader, theme.
- [ ] TestFlight beta on iPhone, iPad and Mac.
- [ ] Submit as the next version of the existing App Store app. Re-enter the
      subtitle ("Bible & Christian Theology"), since a new version can clear it.
- [ ] Notarised DMG release; `updates.json` and the site download page updated.
- [ ] Remove `ios/` and `macos/` from the Flutter project and its CI, delete
      `GlassSurface` and the Apple-imitation theme code, and update the release
      process docs.

## Ongoing rule after launch

Any feature or ranking change lands in both apps, or is recorded in TODO.md as
deliberately platform-specific. The golden tests catch drift in search and
packs; nothing automatic catches drift in features, so this rule has to.

## Risks

- **Foundation Models' context window** is small. Retrieval context must fit,
  as it already has to in the Flutter bridge. Port that budget logic.
- **MLX memory on older iPhones.** Gate the model choice on device memory.
- **Two codebases for one person.** The parity rule above, plus keeping
  CouncilCore small and well-tested, is the mitigation. The Rust option stays
  available if the Swift copy of the core starts drifting from the Dart one.
