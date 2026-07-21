import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'src/services/database_service.dart';
import 'src/services/settings_provider.dart';
import 'src/services/inference/inference_provider.dart';
import 'src/services/search/semantic_search.dart';
import 'src/screens/home_screen.dart';
import 'src/screens/search_screen.dart';
import 'src/screens/browse_screen.dart';
import 'src/screens/chat_screen.dart';
import 'src/screens/bookmarks_screen.dart';

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

  runApp(TheologyApp(
    dbService: dbService,
    settings: settings,
    inference: inference,
  ));
}

class TheologyApp extends StatelessWidget {
  final DatabaseService dbService;
  final SettingsProvider settings;
  final InferenceProvider inference;

  const TheologyApp({
    super.key,
    required this.dbService,
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
          home: const MainScreen(),
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
  
  final List<Widget> _screens = [
    const HomeScreen(),
    const BrowseScreen(),
    const SearchScreen(),
    const ChatScreen(),
    const BookmarksScreen(),
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
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: 'Browse',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search),
            label: 'Search',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_outlined),
            selectedIcon: Icon(Icons.chat),
            label: 'Chat',
          ),
          NavigationDestination(
            icon: Icon(Icons.bookmark_outline),
            selectedIcon: Icon(Icons.bookmark),
            label: 'Bookmarks',
          ),
        ],
      ),
    );
  }
}