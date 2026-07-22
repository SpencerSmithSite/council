import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
        builder: (context, settings, _) => MaterialApp(
          title: 'Council',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.deepPurple,
              brightness: Brightness.light,
            ),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.deepPurple,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
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
        ),
      ),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;
  
  /// Four areas, in the order they matter.
  ///
  /// Chat is first because asking a question is what the app is for; it used
  /// to be the fourth tab behind a statistics dashboard. Browse, Search and
  /// Bookmarks have collapsed into Read — they were three routes into the same
  /// act. Settings has come out of the bottom of a scrolling list, and the
  /// Library out from behind it, which mattered more once the app began
  /// shipping with only the Bible.
  final List<Widget> _screens = [
    const ChatScreen(),
    const ReadScreen(),
    const LibraryScreen(),
    const SettingsScreen(),
  ];
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.forum_outlined),
            selectedIcon: Icon(Icons.forum),
            label: 'Ask',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: 'Read',
          ),
          NavigationDestination(
            icon: Icon(Icons.library_books_outlined),
            selectedIcon: Icon(Icons.library_books),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}