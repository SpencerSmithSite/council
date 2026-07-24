import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'src/services/database_service.dart';
import 'src/services/settings_provider.dart';
import 'src/services/inference/inference_provider.dart';
import 'src/services/search/semantic_search.dart';
import 'src/services/packs/pack_catalogue.dart';
import 'src/services/packs/pack_provider.dart';
import 'src/services/packs/pack_service.dart';
import 'src/screens/chat_screen.dart';
import 'src/screens/read_screen.dart';
import 'src/screens/library_screen.dart';
import 'src/screens/settings_screen.dart';
import 'src/screens/onboarding_screen.dart';
import 'src/theme/app_theme.dart';
import 'src/theme/glass.dart';
import 'src/theme/glass_controls.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Route every database through the FFI factory backed by a bundled,
  // FTS5-enabled SQLite (sqlite3_flutter_libs). Without this the app opens the
  // platform's system SQLite, and Android's build has no FTS5 module — so the
  // lexical half of hybrid search threw `no such module: fts5` and the whole
  // Ask flow failed on Android while working on Apple. Must run before any
  // database is opened.
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Initialize database
  final dbService = DatabaseService();
  await dbService.initialize();

  // Load persisted preferences before the first frame so the app doesn't flash
  // the wrong theme on launch.
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
  // say what it costs — so the first time anyone sees the offer, it is the one
  // time it cannot tell them the price.
  unawaited(packs.refresh());

  runApp(TheologyApp(
    dbService: dbService,
    packs: packs,
    settings: settings,
    inference: inference,
  ));
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
              child: child ?? const SizedBox.shrink(),
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

  final _scaffoldKey = GlobalKey<ScaffoldState>();

  Widget _screenFor(_Area area) => switch (area) {
        _Area.ask => const ChatScreen(),
        _Area.read => const ReadScreen(),
        _Area.library => const LibraryScreen(embedded: true),
      };

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

          // Top-right: settings.
          Positioned(
            top: top + 8,
            right: AppleMetrics.edgeInset,
            child: GlassBubble(
              icon: AppIcons.settings,
              tooltip: 'Settings',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The navigation sidebar, listing the primary areas.
class _NavigationDrawer extends StatelessWidget {
  final _Area current;
  final ValueChanged<_Area> onSelect;

  const _NavigationDrawer({required this.current, required this.onSelect});

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
                area: area,
                selected: area == current,
                onTap: () => onSelect(area),
              ),
          ],
        ),
      ),
    );
  }
}

class _DrawerRow extends StatelessWidget {
  final _Area area;
  final bool selected;
  final VoidCallback onTap;

  const _DrawerRow({
    required this.area,
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
                Icon(area.icon, color: color, size: 22),
                const SizedBox(width: 14),
                Text(
                  area.title,
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