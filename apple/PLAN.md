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
  golden/search/      search fixtures both apps are tested against
  golden/packs/       pack-format fixtures both apps are tested against
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

### Phase 0 — Groundwork (done 2026-11-02)
- [x] `apple/Council.xcodeproj`, generated by XcodeGen from `apple/project.yml`
      (multiplatform app, deployment target 26, the existing bundle ID and team
      Y2Q5JVG8X5), the `CouncilCore` local package, and a bare SwiftUI tab
      shell. See `apple/README.md`.
- [x] Search golden fixtures: `shared/golden/search/search.json`, 37 queries
      against the bundled core corpus, recording every stage (token ids, query
      vector, vector top-N, entities, FTS match, tags, the Read tab's search,
      and the chat retrieval's lexical, semantic, fused and final lists).
      `tools/search_goldens.sh` verifies them on macOS (`--update`
      regenerates), because the sandboxed macOS test build can't read or write
      the repo directly. `test/search_golden_test.dart` checks the
      native-free stages in the normal CI run. The fixture README lists what
      will be awkward to mirror in Swift: score ties, accumulation order, and
      SQL with no tie-breaking `ORDER BY`.
- [x] Pack golden fixtures: `shared/golden/packs/`, built by
      `tools/build_pack_goldens.py` on top of `build_packs.py`. They cover the
      install, overlap, reinstall, uninstall and replace lifecycle plus four
      refusals (wrong idSpace, wrong embedding model, checksum mismatch,
      reshaped table). `test/pack_golden_test.dart` runs them through the real
      `PackService`.
- [x] CI: `.github/workflows/apple.yml` checks that the project matches
      `project.yml`, runs the `CouncilCore` tests on macOS, and builds for the
      iOS Simulator. The Swift side of the golden tests arrives with Phase 1.

### Phase 1 — CouncilCore: corpus, packs, search (done 2026-11-03)
- [x] Corpus install and open (`Corpus/`): the bundled `theology.db.gz` is
      installed into the given directory with the `theology.corpus-version`
      stamp and reinstalled when the stamp is stale. It opens as a GRDB
      `DatabasePool` in WAL mode with foreign keys off (as sqflite has them),
      so searches never wait behind a pack merge. WAL persists, so a corpus
      inherited from the Flutter install becomes three files. The two apps
      never share the file.
- [x] Packs (`Packs/`): manifest and catalogue, the idSpace and
      embedding-model checks, download through an injectable `PackFetcher`,
      SHA-256 checks, gunzip, then a positional merge with branches first,
      reference-counted uninstall, and atomic replacement of stale fragments.
      All six scenarios in `shared/golden/packs` match.
- [x] Search building blocks (`Search/`): WordPiece tokenizer, vector index
      (scores bit-identical to Flutter's), entity recogniser, `HybridRanker`,
      `QueryShaping`. They reproduce Dart's UTF-16 string semantics where Swift
      would otherwise compare by Unicode canonical equivalence.
- [x] Query encoder: the same `.onnx` file on ONNX Runtime 1.24.2, with
      `MatMulIntegerToFloatFusion` turned off. That leaves 35 of 37 queries
      within 1e-7 of Flutter's ORT 1.15.1; `ent-catholic` and `edge-long` are
      recorded as known issues, with cosine similarity ≥ 0.99997. ORT is pinned
      by a test, because the numbers move between versions.
- [x] Retrieval (`Retrieval` actor, `SemanticSearch` actor): the Read tab's
      search and `searchForRAG` with every stage. If the model fails to load,
      search continues lexical-only. `contentDidChange()` is meant to be
      passed as PackService's `onContentChanged`.
- [x] Gate: every golden stage matches on all 37 queries (`read` and every
      `rag` sub-stage) when ranking from the recorded query vectors. A smoke
      test with the real encoder returns the same final ids on the 6 queries
      it runs. Result: `swift test` passes 139 tests (2 known issues), and the
      app builds for iOS Simulator and macOS.

### Phase 2 — App shell and design system (done 2026-11-03, one check open)
- [x] Top-level navigation with the same sections as the Flutter app: a tab
      bar on iPhone that becomes a sidebar on iPad and Mac
      (`.sidebarAdaptable`), and the tab bar shrinking on scroll.
      The Phase 0 shell follows `lib/main.dart`: Ask, Read and Browse as
      primary tabs, a Library section (Notes, Bookmarks, Chat History),
      a search-role tab, and Settings behind a gear (a `Settings` scene on
      the Mac). Decided: in compact width a single Library tab lists Notes,
      Bookmarks and Chat History (the compact tab bar otherwise flattens the
      section and pushes them into a "More" tab); the sidebar and the
      regular-width iPad tab bar show the section natively. See `RootView`.
- [x] App shell wired to CouncilCore: `AppModel` installs the corpus in
      Application Support (Flutter's directory on iOS), loads semantic search
      behind it, and owns `Retrieval` and `PackService`. The search tab shows
      real results. The build refuses to run without the embedding model.
- [x] Theme system. `shared/themes.json` is the one source for all 24 themes.
      `tools/generate_themes.py` writes both `lib/src/theme/themes.g.dart` and
      `CouncilCore/Themes/ThemeCatalogue.g.swift`, and CI runs `--check` on
      both. Flutter's palette derivation is ported to Swift and matches
      `shared/golden/themes/derived.json` exactly (48 theme variants plus
      Apple light and dark). `ThemeStore` persists the Flutter keys
      `theme_id` and `theme_mode`. `ThemePickerView` has live previews.
      Default uses SwiftUI system colours; custom palettes tint the content
      and the accent, and leave the bars as system glass.
      **Rules for every later screen:** put `.councilScreenBackground()` on
      each screen root inside a navigation stack (stacks paint over anything
      set outside them), put `.councilListRow()` on list and form rows, and
      take text colours from `@Environment(\.councilPalette)` (`text`,
      `secondaryLabel`). Never use `.tertiary`, which ignores the theme and
      is illegible on dark palettes.
- [ ] Check the system accessibility settings in every theme. Done so far,
      on the iPhone 17 simulator in Default and Gruvbox dark: Dynamic Type at
      the largest accessibility size (rows wrap correctly) and Increase
      Contrast (the glass gets more defined). Still to do: Reduce
      Transparency and Reduce Motion (simctl can't set them; use Settings in
      the simulator or a device), and a pass over the remaining themes once
      the real screens exist (Phase 3+).

### Phase 3 — Reading (done 2026-11-03, checks open)
Started 2026-11-03. The reader is the one place the native app deliberately
differs from Flutter's shape: Flutter pages a work one section at a time, the
native reader scrolls through the whole work.

**Design**
- **One scroll per work.** A `ScrollView` over a `LazyVStack` of every
  section of the source, each section's text fetched as it nears the screen
  (`Library.contentUnits(ids:)`, a batch around what's visible) and its
  highlights with it. The section at the top of the screen is the reading
  position, saved as Flutter saves it (`reading_position_<sourceId>`, a
  section index), so Phase 7 carries places across. Opening at a unit (a
  citation, a bookmark, later a search hit) scrolls to that section's id.
- **Passage text is a platform text view**, `UITextView` / `NSTextView`
  (TextKit 2), not editable and with the system's own selection off, wrapped
  for SwiftUI. Tapping picks the segment under the finger (a custom attribute
  carries the segment index), as Flutter's reader does: a verse, a paragraph,
  or a sentence of a long paragraph (`SegmentedPassage`). SwiftUI `Text`
  can't do this: it has no hit-testing by character range, and making each
  segment a link brings the link long-press preview and has VoiceOver
  announce every verse as a link. Highlights are background colours from
  `HighlightColour` (light and dark values); the selection wash is the tint
  at 20% (32% in dark), as in Flutter. Segment offsets are UTF-16, which is
  what `NSString` ranges use, so stored highlights from either app line up.
- **The action bar is the system toolbar.** While segments are selected, a
  bottom toolbar (iOS/iPadOS, system glass) or window toolbar items (Mac)
  offer Copy, Share (`ShareLink`), Highlight (a `Menu` with a palette picker
  of the five colours, plus Remove Highlight when the selection has one),
  Note and Ask, with the count ("3 verses") as the title. The same actions
  are the context menu on long-press or right-click, which selects the
  segment under it first. Ask opens the Ask tab's placeholder until Phase 5
  wires the pinned passage.
- **Books-style reading controls** behind an "Aa" toolbar button: a sheet at
  a medium detent on iPhone, a popover on iPad and Mac. Text size (− / +),
  font (System, New York, Iowan Old Style, Palatino, Georgia, Charter), line
  spacing, margins, justification, and the theme (the catalogue's themes as
  swatches, plus Auto / Light / Dark). Keys: `font_size` (Flutter's, a
  0.8–1.5 multiplier on the Dynamic Type body size, so the reader still
  follows the system size) and new `reader_font`, `reader_line_spacing`,
  `reader_margins`, `reader_justified`.
- **Contents** behind a list button: a sheet with `.searchable` filtering. A
  work with books ("Genesis 1", "Genesis 2", …, decided once from the whole
  work by `ContentsIndex`) shows each book with a grid of chapter numbers,
  as Books does; anything else is a plain list.
- **Bookmark** toggle in the reader's toolbar for the section at the top,
  the same passage-level bookmarks the content detail screen sets.
- **Browse moves to Phase 6.** In the Flutter app Browse is the content-pack
  library, so it is built with the rest of the pack UI.

**Work** (done 2026-11-03, checks open)
- [x] CouncilCore `Reading/`: `SegmentedPassage` and `PassageCitation`
      (reference and quote), `HighlightColour`, `ContentsIndex`,
      `RelativeDate`. `shared/golden/segments/` (87 cases: 31 KJV chapters
      and 56 hand-written edge cases, generated from the Dart code by
      `tools/build_segment_goldens.py`, verified by
      `test/segments_golden_test.dart`) matches exactly. Dart's `\d`, `\s`,
      multiline `^` and `trim()` differ from ICU's, so the Swift side scans by
      hand instead of using NSRegularExpression; see the fixture README.
- [x] CouncilCore `UserData/`: `council_user.db` with sqflite's schema and
      `user_version` (checked both ways against a file made by the Dart code),
      a `DatabaseQueue` so the file stays out of WAL; `AnnotationStore` with a
      change stream; `BookmarkStore`, `ShelfStore`, `ReadingPositionStore`,
      `ReaderPreferences` on the Flutter keys and encodings, including Dart's
      local ISO dates (`DartDateTime`). `Corpus/Library`.
- [x] Source reader (`Features/Reader/`): continuous scroll, the TextKit 2
      passage view with per-segment accessibility elements, selection
      toolbar and context menu, highlight palette, note sheet, reading
      controls (`ReaderStyle`), contents with chapter grids, bookmark. The
      selection count is the navigation subtitle, as in Photos and Files,
      because in the bottom bar it pushed three of the five actions into an
      overflow menu. Ask is shown disabled until Phase 5. The passage
      screen (`ContentDetailView`); search results now open it.
- [x] Read shelf, Notes (notes and highlights), note editor (saves as you
      type, abandons an untouched new note), Bookmarks.
- [ ] Open items:
      - VoiceOver run for real on a device; on the Mac the per-segment
        accessibility frames are about 59pt off.
      - Mac context menu: item icons and the palette swatches don't show.
      - iOS palette picker draws a thin square outline round each colour.
      - Scrolling upward through sections that load late can shift the page
        (jumps are corrected, slow scrolling isn't).
      - Prose and sentence segments not seen on screen (the seed corpus is
        KJV only); check with packs installed.
      - The reader doesn't reload on `contentRevision` (pack changes).
      - iPad: the Aa popover and the shelf with interaction.
- Found in the Dart segmenter while building the fixture, recorded as is so
  both apps agree (fix both together, regenerating the fixture):
  `St. Paul` and `Mr. Smith` split as sentences, contrary to the comment on
  `_sentenceEnd`; a closing curly quote (`”`) never ends a sentence; CRLF
  blank lines aren't paragraph breaks; text above verse 1 is never split
  however long; `_labelFor` cuts the stem from the untrimmed title.

### Phase 4 — Search (done 2026-11-03)
- [x] The Search tab: the Read tab's query (`lexicalSearch`, limit 40,
      FTS5 then LIKE), results grouped by work in order of each work's best
      match, each row the verse or paragraph that matched with the matched
      words in bold (`SearchHits`, `SearchSnippet` in CouncilCore). The
      matched words are re-found in Swift, folded as FTS5's `unicode61`
      folds them, rather than with FTS5's `highlight()`, so the shared,
      golden-tested query is untouched. Recent searches (`recent_searches`,
      native-only) when the field is empty.
- [x] A result opens the whole work in the reader at that section, with the
      matched words marked in the system yellow and the first scrolled to a
      quarter of the way down (`ReadingRoute.source(find:)`). The marks clear
      when the reader starts selecting.
- [x] The shelf's filter offers "Search Passages for …", which hands the
      query to the Search tab (Flutter's submit-to-search on the Read tab).
- [ ] Open: the iOS 26 search tab that becomes a field in the tab bar. With
      `.searchable` on the TabView the search tab stays an ordinary tab in
      this tab bar (seen in Phase 2 too) and no field appears, so the field
      is pinned under the title instead (`.navigationBarDrawer(.always)`).
      Worth another look once the tab set is final.
- [ ] Open: a unit FTS matched only on its title shows its opening and marks
      nothing.

### Phase 5 — AI (done 2026-11-04, checks open)
Started 2026-11-03.

**Design**
- **Core first, in two parallel pieces.** CouncilCore `Inference/`: the
  `InferenceBackend` contract (written first, so both pieces build on it),
  `ReasoningFilter`, `ChatPrompt` held to a new `shared/golden/prompts/`
  fixture generated from the Dart, `Citation` with Dart's JSON,
  `ChatHistoryStore` on `council_user.db`, `InferenceSettings` on Flutter's
  keys, cloud keys in the Keychain, and the Foundation Models, Ollama and
  cloud backends. `Inference/Local/`: the MLX backend, model catalogue,
  download and storage.
- **The Ask tab is a transcript and a composer,** both standard: a scroll
  view of messages, the composer a glass bar at the bottom (`TextField` with
  axis vertical in a `.safeAreaBar`/bottom toolbar), Send turning into Stop
  while an answer streams. The answer follows the stream until the reader
  scrolls up, with a jump-to-latest button, as in Flutter.
- **Markdown**: answers are rendered block by block from
  `AttributedString(markdown:)` with full syntax, walking its
  `presentationIntent` (paragraphs, lists, quotes, headings, code), so no
  third-party renderer. Citation markers `[1]` become tappable.
- **Citations** under each answer: the source, author and tradition, the
  traceable/untraced badge, opening the passage
  (`ReadingRoute.passage`). The reliability caveat on the first generated
  answer in a thread, as Flutter.
- **Ask about a passage**: the reader's Ask action switches to the Ask tab
  with the passage pinned (a banner above the transcript); it leads the
  prompt and names the thread.
- **History**: Chat History lists threads (swipe to delete); opening one
  continues it in the Ask tab.
- **The AI backend screen** in Settings: the backends as a picker list with
  their privacy line and live status; Foundation Models' availability states
  (with the "Apple Intelligence is off" hint and a link to Settings); MLX
  model choice, download progress, storage used, delete; Ollama host and
  model list; cloud provider, key (secure field, Keychain) and model.
- The coverage notice ("a collection that would help isn't installed"),
  done 2026-11-04: `PackLibrary` (Flutter's `PackProvider`: the bundled
  `pack_catalogue.json`, installed fragments, the manifest fetched on
  demand, one install with progress) on `AppModel`; `CoverageNotice` above
  the composer with "Add <collection> · <size>", which installs and asks
  the question again. Checked in the iPhone simulator: an Orthodox question
  on the bare library, Add Creeds & Confessions, progress, then a cited
  answer from the Orthodox catechism. Flutter's second button, "Browse
  library", waits for Phase 6's Browse.

**Work**
- [x] Core, in CouncilCore (2026-11-03): `ReasoningFilter`; `ChatPrompt` and
      `Citation`, matching `shared/golden/prompts/prompts.json` (21 cases,
      written by `test/chat_prompt_golden_test.dart` from the prompt building
      now pulled out of the chat screen into `chat_prompt.dart`);
      `ChatHistoryStore`; `InferenceSettings` on Flutter's keys with the
      opening-backend rule; `SecretStore` (Keychain service
      `site.spencersmith.council.cloud`, account = provider id; Flutter's
      item names recorded on `KeychainSecretStore` for Phase 7);
      `OllamaBackend`, `CloudBackend`, `FoundationModelsBackend` over an
      injectable `HTTPTransport`; `Generation`, the stream driver the chat
      screen consumes (Stop that always stops, a stall limit, outcomes worded
      as Flutter's screen words them). Deliberate differences from Dart: an
      error event inside a stream (Ollama `{"error"}`, a provider's SSE error)
      ends the answer with that error, where Dart skips it and stores the
      truncated answer as complete; a cloud error body whose `error` is a
      string is shown, where Dart throws a type error; Foundation Models'
      context-overflow and guardrail failures get sentences of their own.
      Fixed in both apps (2026-11-04): a failed answer's partial text, which
      stays on screen, is now stored too, ahead of the error, so a reopened
      thread shows what the screen showed (`Generation.Outcome
      .persistsAnswer`; Flutter's `_streamAnswer`, with a widget test).
- [x] Backends: Foundation Models, MLX local model (download, progress,
      storage, delete), Ollama on the local network
      (`NSLocalNetworkUsageDescription`), and cloud (Anthropic, OpenAI,
      Gemini, xAI) with keys in Keychain. The MLX backend
      (`Inference/Local/`, mlx-swift-lm 3.32.3 + swift-transformers 1.3.5
      Tokenizers): Qwen3 0.6B, 1.7B, 4B Instruct 2507 and 8B, 4-bit, pinned
      revisions, hash-checked resumable downloads into Application Support
      `MLXModels/`, thinking off through the chat template
      (`enable_thinking: false`), greedy decoding. Smoke test on an M4 Mac:
      0.6B at 153 tokens/s in Release, peak 701 MB. Unavailable in the
      Simulator and on Intel Macs, by design. Open: MLX not yet run on an
      iPhone or iPad; the 1.7B's phone memory floor (7,000 MB, admitting
      8 GB iPhones) is untested on a real phone; release archives must be
      arm64-only or MLX checked for x86_64; CI now needs Xcode 26.4+ (Swift
      tools 6.3) and has not run on GitHub yet.
- [x] Streaming, the reasoning filter, citations into the reader, chat
      history (2026-11-03). `InferenceModel` (on `AppModel`) owns the
      settings, Keychain, the shared `LocalModelStore`, Apple Intelligence's
      availability, the resolved backend and its status, rebuilding when an
      inference key changes in `UserDefaults` (call `reload()` after a
      Keychain change). The Ask tab (`ChatView` over `ChatSession`, Flutter's
      send flow with an epoch guard on every reply), `MarkdownText` (block
      renderer over `presentationIntent`, `[n]` markers as links), Ask about
      a passage from the reader (`AppModel.ask(about:)`), Chat History
      handing threads back to Ask. Checked with Foundation Models on the Mac
      and the iPhone 17 simulator, and Qwen 3 0.6B on MLX on the Mac.
      Differences from Flutter: while an answer streams its sources are one
      line ("Drawing on 6 sources") so following keeps the newest words in
      view; opening the thread already on screen from History doesn't stop
      its answer; the history preview strips inline Markdown; citations are
      always shown (Flutter's `show_citations` setting isn't ported yet).
      Open: several Mac windows share
      `pendingAsk` as they share `pendingSearch`, so an Ask request is taken
      by whichever window's `RootView` sees it.
- [x] The AI backend screen: availability states matching
      `PlatformLlmState`, including the "Apple Intelligence is off" hint
      (2026-11-04). `AIBackendView`, a grouped `Form` pushed from Settings
      (whose row shows the current backend): live status with a re-check;
      the backends as an inline picker with Flutter's summaries and a
      privacy line each; Apple Intelligence's off/downloading states with
      Open Settings (iOS) / System Settings' Siri pane (Mac) and Check
      Again; the downloaded model's tiers (recommended marked, memory
      note), Download with the disk check, progress with bytes and Cancel,
      Resume and Delete (confirmed), space used, other models on disk, and
      the Simulator/Intel `unsupportedReason` instead; Ollama host
      (validated, trimmed), connection test in Flutter's words, model
      picker from the host; cloud provider and model pickers, key in a
      `SecureField` to the Keychain, Get a Key link, Remove Key, the
      off-device warning. Downloads live in `InferenceModel.downloads`
      (`LocalModelDownloads`), so they survive leaving the screen.
      Checked on the Mac (download, leave and return, cancel, delete the
      partial; Ollama reachable and unreachable) and the iPhone 17
      simulator (Default, Gruvbox dark, Solarized Light, accessibility
      text sizes; cloud key saved and removed). On the Mac the
      data-protection keychain refused every write (`errSecMissingEntitlement`,
      -34018: it needs a `keychain-access-groups` entitlement and so a
      provisioning profile), so `KeychainSecretStore` uses the login keychain
      on macOS, the usual home for an unsandboxed Developer ID app's
      passwords; iOS keeps the data-protection keychain (round trip tested
      on the Mac). Flutter's `show_citations` lives on its Settings screen,
      so it waits for Phase 6.

### Phase 6 — Settings, onboarding, updates
- [ ] Browse, the content-pack library (`browse_screen.dart`), on
      `PackCatalogue` and `PackService`; Settings' Content Packs opens it too.
- [ ] Settings, onboarding, update check against the existing `updates.json`.
- [x] Onboarding (2026-11-04), `Features/Onboarding/`: Flutter's three steps
      (Scripture, the library with Creeds & Confessions preselected, Answers)
      as a `NavigationStack` of grouped forms under large SF Symbol headers,
      `.glassProminent` Continue / Get Started, Skip on every step; a
      full-screen cover on iPhone, a sheet on iPad and Mac (Back beside
      Continue there). The AI step reuses the AI backend screen's rows and
      sections (opening on the backend `resolveBackend` chose: Apple
      Intelligence when ready, else the downloaded model with its size).
      Get Started queues the collections in `OnboardingGate`, which outlives
      the sheet; a downloads page follows them and Start Reading closes it
      while they carry on. `has_onboarded` (no prefix) is written when the
      reader commits. Not shown when `has_onboarded` or
      `flutter.has_onboarded` is set, or when the library already holds a
      highlight, note, conversation or installed collection
      (`ExistingInstall`, read before the files are opened; the flag is then
      written). Phase 7's Mac copy must run before `OnboardingGate.decide`.
      Checked on the iPhone Air simulator (Default, Gruvbox dark/light, AX5
      text; Get Started with 1 and 3 collections, Start Reading mid-download,
      Skip; relaunch; existing user by installed pack and by the Flutter
      flag) and on the Mac (sheet; existing user). Open: Settings' "Show
      Onboarding" (call `model.onboarding.replay()`); Apple Intelligence off
      or unsupported not seen (the simulator reports it ready); iPad not run.
- [ ] Mac: port the `_macos` path of `update_installer.dart` (download DMG,
      verify, replace, relaunch).

### Phase 7 — Migration from the Flutter install
The native app installs over the Flutter one with the same bundle ID, so the
data is still on the device. The new app just has to read it.
- [ ] `council_user.db`, the corpus and `packs/` in Application Support: open
      them in place on iOS and iPadOS (same schema).
- [ ] **Mac: the Flutter app was sandboxed, the native one is not.**
      `macos/Runner/Release.entitlements` turns on `app-sandbox`, so the
      Flutter Mac app's files, preferences and Keychain items live under
      `~/Library/Containers/site.spencersmith.council/Data/`, while the
      unsandboxed native app looks in `~/Library/Application Support/` and
      `~/Library/Preferences/`. On first launch, copy the user database
      (and packs, if present) out of the container, read the old preferences
      plist from the container's `Library/Preferences/`, and check whether
      the Keychain items are reachable from outside the sandbox. If they
      aren't, ask the user to re-enter cloud keys and don't fail silently.
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
