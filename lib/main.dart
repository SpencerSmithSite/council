import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'src/services/database_service.dart';
import 'src/services/settings_provider.dart';
import 'src/services/inference/inference_provider.dart';
import 'src/services/inference/local_model_backend.dart';
import 'src/services/search/semantic_search.dart';
import 'src/services/packs/pack_catalogue.dart';
import 'src/services/packs/pack_provider.dart';
import 'src/services/packs/pack_service.dart';
import 'src/services/updates/update_provider.dart';
import 'src/screens/chat_history_screen.dart';
import 'src/screens/chat_screen.dart';
import 'src/screens/notes_screen.dart';
import 'src/screens/read_screen.dart';
import 'src/screens/library_screen.dart';
import 'src/screens/settings_screen.dart';
import 'src/screens/onboarding_screen.dart';
import 'src/theme/app_theme.dart';
import 'src/theme/glass.dart';
import 'src/theme/glass_controls.dart';
import 'src/widgets/brand_loader.dart';
import 'src/widgets/update_sheet.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Route every database through the FFI factory backed by a bundled,
  // FTS5-enabled SQLite (sqlite3_flutter_libs). Without this the app opens the
  // platform's system SQLite, and Android's build has no FTS5 module — so the
  // lexical half of hybrid search threw `no such module: fts5` and the whole
  // Ask flow failed on Android while working on Apple. Must run before any
  // database is opened.
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Show a first frame immediately (the branded splash) and do the heavy
  // startup work behind it, rather than blocking on a blank native splash. On
  // a fast device this barely flashes; on a slow one — or a slow first network
  // call — the reader sees the mark breathing instead of a frozen screen.
  runApp(const _CouncilBootstrap());
}

/// Runs the app's asynchronous startup, showing [BrandSplash] until it finishes.
///
/// Kept out of `main()` so the framework is already mounted and painting the
/// splash while the database decompresses, the embedding model loads (~20 MB),
/// and the installed library is read. There is deliberately no minimum splash
/// time: if startup is instant the reader should not be made to wait.
class _CouncilBootstrap extends StatefulWidget {
  const _CouncilBootstrap();

  @override
  State<_CouncilBootstrap> createState() => _CouncilBootstrapState();
}

class _CouncilBootstrapState extends State<_CouncilBootstrap> {
  late final Future<TheologyApp> _app = _bootstrap();

  Future<TheologyApp> _bootstrap() async {
    await _initialiseLocalModelRuntime();

    // Initialize database
    final dbService = DatabaseService();
    await dbService.initialize();

    // Load persisted preferences before the first frame so the app doesn't
    // flash the wrong theme on launch.
    final settings = SettingsProvider();
    await settings.load();

    final inference = InferenceProvider();
    await inference.load();

    // Semantic retrieval is loaded after the database and treated as optional:
    // it costs ~20 MB and a moment of startup, and a device that cannot run the
    // model should still get a searchable library rather than a failed launch.
    dbService.semantic = await SemanticSearch.tryLoad(dbService.database);

    // Reloading the vector index after a pack changes is not optional: it is a
    // snapshot taken at startup, so without it newly installed text is found by
    // lexical search and ignored by semantic search.
    final packs = PackProvider(
      PackService(
        dbService.database,
        onContentChanged: () async => dbService.semantic?.reload(),
      ),
      await PackCatalogue.load(),
    );
    await packs.loadInstalled();
    // Fetched at startup rather than when the Library is first opened. It is
    // 1.4 KB, and without it the coverage notice can name a collection but not
    // say what it costs. Not awaited, so a slow network never holds up launch.
    unawaited(packs.refresh());

    return TheologyApp(
      dbService: dbService,
      packs: packs,
      settings: settings,
      inference: inference,
    );
  }

  /// Registers the engine that runs a downloaded model.
  ///
  /// `flutter_gemma` has been a core package with no engine of its own since
  /// 1.0: without both this call and an engine package, the first download
  /// fails with "FlutterGemma not initialized" and the downloadable-model
  /// backend is dead on arrival.
  ///
  /// LiteRT-LM rather than MediaPipe, because it is the only one of the two
  /// that runs on desktop as well as phones. That is what lets one engine and
  /// one model cover all five platforms instead of a mobile pair and a desktop
  /// pair drifting apart.
  ///
  /// Cheap — it wires up a registry and touches no weights — but deliberately
  /// awaited before anything else, because it must be in place before any
  /// screen can reach the model settings.
  Future<void> _initialiseLocalModelRuntime() async {
    if (!LocalModelChoice.runsHere) return;
    try {
      await FlutterGemma.initialize(
        inferenceEngines: const [LiteRtLmEngine()],
      );
    } catch (e) {
      // A reader who is not using a downloaded model should still get a
      // working library, so this must not be able to fail the launch. The
      // backend's own checkStatus reports the problem if they do try to use it.
      debugPrint('Local model runtime unavailable: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TheologyApp>(
      future: _app,
      builder: (context, snapshot) {
        if (snapshot.hasData) return snapshot.data!;

        // The splash needs the basic app scaffolding (Directionality, a media
        // query) around it, but not a theme — it paints its own indigo.
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          home: snapshot.hasError
              ? _BootstrapError(error: snapshot.error!)
              : const BrandSplash(message: 'Preparing your library…'),
        );
      },
    );
  }
}

/// Shown if startup itself fails — rare, but better than a splash that never
/// resolves.
class _BootstrapError extends StatelessWidget {
  final Object error;

  const _BootstrapError({required this.error});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40),
              const SizedBox(height: 16),
              const Text(
                'Council could not start.',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text('$error', textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}

class TheologyApp extends StatelessWidget {
  final DatabaseService dbService;
  final PackProvider packs;
  final SettingsProvider settings;
  final InferenceProvider inference;

  const TheologyApp({
    super.key,
    required this.dbService,
    required this.packs,
    required this.settings,
    required this.inference,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<DatabaseService>.value(value: dbService),
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ChangeNotifierProvider<InferenceProvider>.value(value: inference),
        ChangeNotifierProvider<PackProvider>.value(value: packs),
        // Constructed here rather than in the bootstrap because it must not
        // touch the network before the first frame: the launch check is
        // deliberately something that happens *behind* a usable app.
        ChangeNotifierProvider<UpdateProvider>(
          create: (_) => UpdateProvider(),
        ),
      ],
      child: Consumer<SettingsProvider>(
        builder: (context, settings, _) {
          final themes = resolveThemes(settings.themeId);
          return MaterialApp(
          title: 'Council',
          theme: themes.light,
          darkTheme: themes.dark,
          themeMode: settings.themeMode,
          // Apply the font-size preference app-wide rather than per-screen.
          builder: (context, child) {
            final media = MediaQuery.of(context);
            return MediaQuery(
              data: media.copyWith(
                textScaler: TextScaler.linear(settings.fontScale),
              ),
              // Tapping away from a field dismisses the keyboard, on every
              // screen including pushed ones.
              //
              // iOS gives a text field no escape of its own: a multi-line
              // composer's return key inserts a newline, and a form field
              // behind the keyboard cannot be scrolled if its screen does not
              // scroll — so the keyboard could take half the display with
              // nothing on screen able to close it. Translucent, so buttons
              // and list rows still receive their own taps; the arena gives
              // the tap to the innermost recognizer and this only fires when
              // nothing else claims it.
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                child: child ?? const SizedBox.shrink(),
              ),
            );
          },
          // First run goes to setup. Gated on a stored flag rather than on an
          // empty library, so someone who deliberately removed everything is
          // not walked through setup again on every launch.
          home: settings.hasOnboarded
              ? const MainScreen()
              : const OnboardingScreen(),
          );
        },
      ),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  
  @override
  State<MainScreen> createState() => _MainScreenState();
}

/// The three primary areas.
///
/// Asking is what the app is for, so Ask is first. Browse, Search and Bookmarks
/// collapsed into Read — three routes into one act. Settings is no longer one
/// of these: on Apple it belongs in the top-right corner, not in the primary
/// navigation, so it is reached by the floating gear rather than listed here.
enum _Area {
  ask('Ask'),
  read('Read'),
  library('Library');

  const _Area(this.title);
  final String title;

  IconData get icon => switch (this) {
        _Area.ask => AppIcons.ask,
        _Area.read => AppIcons.read,
        _Area.library => AppIcons.library,
      };
}

class _MainScreenState extends State<MainScreen> {
  _Area _area = _Area.ask;

  @override
  void initState() {
    super.initState();
    // After the first frame, not during it: this is a network call, and the
    // reader is here to read rather than to wait for one. It says nothing at
    // all unless a newer build exists — no spinner, no error on a device with
    // no connection.
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate());
  }

  Future<void> _checkForUpdate() async {
    final updates = context.read<UpdateProvider>();
    await updates.checkOnLaunch(
      enabled: context.read<SettingsProvider>().autoCheckUpdates,
    );
    if (!mounted || updates.release == null) return;
    await UpdateSheet.show(context);
  }

  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Reaches into the Ask tab so the compose button can start a new thread,
  /// and so a conversation chosen in the history list can be opened *there*
  /// rather than in a second screen showing the same thread.
  final _chatKey = GlobalKey<ChatScreenState>();

  Widget _screenFor(_Area area) => switch (area) {
        _Area.ask => ChatScreen(key: _chatKey),
        _Area.read => const ReadScreen(),
        _Area.library => const LibraryScreen(embedded: true),
      };

  Future<void> _openHistory() async {
    final id = await Navigator.push<int>(
      context,
      MaterialPageRoute(builder: (_) => const ChatHistoryScreen()),
    );
    if (id == null || !mounted) return;
    setState(() => _area = _Area.ask);
    await _chatKey.currentState?.openConversation(id);
  }

  @override
  Widget build(BuildContext context) {
    // On Apple the navigation is a left drawer opened from a floating bubble,
    // with settings floating top-right and the content full-bleed behind both —
    // the iOS 26 pattern where chrome hovers over content as detached glass
    // rather than sitting in solid bars. Elsewhere the same drawer serves, with
    // plain circular buttons.
    final top = MediaQuery.of(context).padding.top;

    return Scaffold(
      key: _scaffoldKey,
      drawer: _NavigationDrawer(
        current: _area,
        onSelect: (area) {
          setState(() => _area = area);
          Navigator.pop(context);
        },
        onOpenNotes: () {
          Navigator.pop(context);
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const NotesScreen()),
          );
        },
        onOpenHistory: () {
          Navigator.pop(context);
          _openHistory();
        },
      ),
      // Full-bleed: the content paints edge to edge so the glass controls have
      // something to refract, and so a list scrolls under them rather than
      // stopping at a bar.
      body: Stack(
        children: [
          Positioned.fill(
            child: IndexedStack(
              index: _area.index,
              children: [for (final a in _Area.values) _screenFor(a)],
            ),
          ),

          // Top-left: open the navigation drawer.
          Positioned(
            top: top + 8,
            left: AppleMetrics.edgeInset,
            child: GlassBubble(
              icon: AppIcons.menu,
              tooltip: 'Menu',
              onTap: () => _scaffoldKey.currentState?.openDrawer(),
            ),
          ),

          // Top-right: settings, and — on Ask only — a compose button, since
          // starting a fresh thread is the one action that has nowhere else to
          // live now that conversations persist across launches.
          Positioned(
            top: top + 8,
            right: AppleMetrics.edgeInset,
            child: Row(
              children: [
                if (_area == _Area.ask) ...[
                  GlassBubble(
                    icon: AppIcons.newChat,
                    tooltip: 'New conversation',
                    onTap: () => _chatKey.currentState?.startNewConversation(),
                  ),
                  const SizedBox(width: 8),
                ],
                GlassBubble(
                  icon: AppIcons.settings,
                  tooltip: 'Settings',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The navigation sidebar: the three primary areas, then the reader's own
/// material below a rule.
///
/// Notes and Chat history are deliberately *not* areas. An area is a place the
/// app can sit in; these two are lists you go into, take something out of, and
/// come back from — Notes opens an editor, and picking a conversation puts it
/// in the Ask tab rather than becoming a fourth destination of its own.
class _NavigationDrawer extends StatelessWidget {
  final _Area current;
  final ValueChanged<_Area> onSelect;
  final VoidCallback onOpenNotes;
  final VoidCallback onOpenHistory;

  const _NavigationDrawer({
    required this.current,
    required this.onSelect,
    required this.onOpenNotes,
    required this.onOpenHistory,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Drawer(
      backgroundColor: scheme.surface,
      shape: isApplePlatform
          ? const RoundedRectangleBorder(
              borderRadius: BorderRadius.horizontal(right: Radius.circular(0)))
          : null,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              child: Text('Council',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      )),
            ),
            const SizedBox(height: 8),
            for (final area in _Area.values)
              _DrawerRow(
                icon: area.icon,
                title: area.title,
                selected: area == current,
                onTap: () => onSelect(area),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Divider(height: 1),
            ),
            _DrawerRow(
              icon: AppIcons.notes,
              title: 'Notes',
              selected: false,
              onTap: onOpenNotes,
            ),
            _DrawerRow(
              icon: AppIcons.history,
              title: 'Chat history',
              selected: false,
              onTap: onOpenHistory,
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  const _DrawerRow({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        shape: squircle(12),
        child: InkWell(
          customBorder: squircle(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                Icon(icon, color: color, size: 22),
                const SizedBox(width: 14),
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 17,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}