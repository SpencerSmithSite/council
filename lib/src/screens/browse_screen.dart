import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/database_service.dart';
import 'content_detail_screen.dart';

class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key});
  
  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  List<Map<String, dynamic>>? _traditions;
  List<Map<String, dynamic>>? _sourceTypes;
  bool _isLoading = true;
  String _viewMode = 'tradition'; // 'tradition' or 'type'
  
  @override
  void initState() {
    super.initState();
    _loadData();
  }
  
  Future<void> _loadData() async {
    final dbService = context.read<DatabaseService>();
    final traditions = await dbService.getTraditions();
    final sourceTypes = await dbService.getSourceTypes();
    
    if (mounted) {
      setState(() {
        _traditions = traditions;
        _sourceTypes = sourceTypes;
        _isLoading = false;
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Browse'),
        actions: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'tradition', label: Text('Tradition')),
              ButtonSegment(value: 'type', label: Text('Type')),
            ],
            selected: {_viewMode},
            onSelectionChanged: (Set<String> selection) {
              setState(() {
                _viewMode = selection.first;
              });
            },
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildContent(),
    );
  }
  
  Widget _buildContent() {
    if (_viewMode == 'tradition') {
      return _buildTraditionsList();
    } else {
      return _buildTypesList();
    }
  }
  
  Widget _buildTraditionsList() {
    if (_traditions == null || _traditions!.isEmpty) {
      return const Center(child: Text('No traditions found'));
    }
    
    return ListView.builder(
      itemCount: _traditions!.length,
      itemBuilder: (context, index) {
        final tradition = _traditions![index];
        return ListTile(
          leading: const Icon(Icons.account_balance),
          title: Text(tradition['name'] ?? 'Unknown'),
          subtitle: Text(tradition['description'] ?? ''),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _navigateToTradition(tradition),
        );
      },
    );
  }
  
  Widget _buildTypesList() {
    if (_sourceTypes == null || _sourceTypes!.isEmpty) {
      return const Center(child: Text('No source types found'));
    }
    
    return ListView.builder(
      itemCount: _sourceTypes!.length,
      itemBuilder: (context, index) {
        final type = _sourceTypes![index];
        return ListTile(
          leading: const Icon(Icons.category),
          title: Text(type['name'] ?? 'Unknown'),
          subtitle: Text(type['description'] ?? ''),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _navigateToType(type),
        );
      },
    );
  }
  
  void _navigateToTradition(Map<String, dynamic> tradition) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TraditionSourcesScreen(
          traditionId: tradition['id'],
          traditionName: tradition['name'],
        ),
      ),
    );
  }
  
  void _navigateToType(Map<String, dynamic> type) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TypeSourcesScreen(
          typeId: type['id'],
          typeName: type['name'],
        ),
      ),
    );
  }
}

class TraditionSourcesScreen extends StatefulWidget {
  final int traditionId;
  final String traditionName;
  
  const TraditionSourcesScreen({
    super.key,
    required this.traditionId,
    required this.traditionName,
  });
  
  @override
  State<TraditionSourcesScreen> createState() => _TraditionSourcesScreenState();
}

class _TraditionSourcesScreenState extends State<TraditionSourcesScreen> {
  List<Map<String, dynamic>>? _sources;
  bool _isLoading = true;
  
  @override
  void initState() {
    super.initState();
    _loadSources();
  }
  
  Future<void> _loadSources() async {
    final dbService = context.read<DatabaseService>();
    final sources = await dbService.getSourcesByTradition(widget.traditionId);
    
    if (mounted) {
      setState(() {
        _sources = sources;
        _isLoading = false;
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.traditionName)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildSourcesList(),
    );
  }
  
  Widget _buildSourcesList() {
    if (_sources == null || _sources!.isEmpty) {
      return Center(child: Text('No sources for ${widget.traditionName}'));
    }
    
    return ListView.builder(
      itemCount: _sources!.length,
      itemBuilder: (context, index) {
        final source = _sources![index];
        return ListTile(
          leading: const Icon(Icons.book),
          title: Text(source['title'] ?? 'Unknown'),
          subtitle: Text(source['date_composed'] ?? ''),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _navigateToSource(source),
        );
      },
    );
  }
  
  void _navigateToSource(Map<String, dynamic> source) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ContentDetailScreen(sourceId: source['id']),
      ),
    );
  }
}

class TypeSourcesScreen extends StatefulWidget {
  final int typeId;
  final String typeName;
  
  const TypeSourcesScreen({
    super.key,
    required this.typeId,
    required this.typeName,
  });
  
  @override
  State<TypeSourcesScreen> createState() => _TypeSourcesScreenState();
}

class _TypeSourcesScreenState extends State<TypeSourcesScreen> {
  List<Map<String, dynamic>>? _sources;
  bool _isLoading = true;
  
  @override
  void initState() {
    super.initState();
    _loadSources();
  }
  
  Future<void> _loadSources() async {
    final dbService = context.read<DatabaseService>();
    final sources = await dbService.getSourcesByType(widget.typeId);
    
    if (mounted) {
      setState(() {
        _sources = sources;
        _isLoading = false;
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.typeName)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildSourcesList(),
    );
  }
  
  Widget _buildSourcesList() {
    if (_sources == null || _sources!.isEmpty) {
      return Center(child: Text('No ${widget.typeName} sources found'));
    }
    
    return ListView.builder(
      itemCount: _sources!.length,
      itemBuilder: (context, index) {
        final source = _sources![index];
        return ListTile(
          leading: const Icon(Icons.book),
          title: Text(source['title'] ?? 'Unknown'),
          subtitle: Text(source['date_composed'] ?? ''),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _navigateToSource(source),
        );
      },
    );
  }
  
  void _navigateToSource(Map<String, dynamic> source) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ContentDetailScreen(sourceId: source['id']),
      ),
    );
  }
}