import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/database_service.dart';
import '../services/search_history_service.dart';
import 'content_detail_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>>? _results;
  List<SearchHistoryItem> _history = [];
  bool _isSearching = false;
  bool _showHistory = true;
  
  final SearchHistoryService _historyService = SearchHistoryService();
  
  @override
  void initState() {
    super.initState();
    _loadHistory();
    _searchController.addListener(_onSearchChanged);
  }
  
  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }
  
  Future<void> _loadHistory() async {
    final history = await _historyService.getHistory();
    setState(() {
      _history = history;
    });
  }
  
  void _onSearchChanged() {
    final text = _searchController.text;
    setState(() {
      _showHistory = text.isEmpty;
      if (text.isEmpty) {
        _results = null;
      }
    });
  }
  
  Future<void> _performSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _results = null;
        _isSearching = false;
        _showHistory = true;
      });
      return;
    }
    
    setState(() {
      _isSearching = true;
      _showHistory = false;
    });
    
    final dbService = context.read<DatabaseService>();
    final results = await dbService.search(query.trim());
    
    if (mounted) {
      setState(() {
        _results = results;
        _isSearching = false;
      });
    }
    
    // Save to history
    await _historyService.addSearch(query.trim());
    _loadHistory();
  }
  
  Future<void> _clearHistory() async {
    await _historyService.clearHistory();
    setState(() {
      _history = [];
    });
  }
  
  Future<void> _removeHistoryItem(String query) async {
    await _historyService.removeSearch(query);
    _loadHistory();
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Search'),
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search theological content...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _results = null;
                            _showHistory = true;
                          });
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
              ),
              onSubmitted: _performSearch,
            ),
          ),
          
          // Results or History
          Expanded(
            child: _isSearching
                ? const Center(child: CircularProgressIndicator())
                : _showHistory
                    ? _buildHistory()
                    : _buildResults(),
          ),
        ],
      ),
    );
  }
  
  Widget _buildHistory() {
    if (_history.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'Search across creeds, confessions,\nand church fathers',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Recent Searches',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              TextButton(
                onPressed: _clearHistory,
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _history.length,
            itemBuilder: (context, index) {
              final item = _history[index];
              return ListTile(
                leading: const Icon(Icons.history),
                title: Text(item.query),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => _removeHistoryItem(item.query),
                ),
                onTap: () {
                  _searchController.text = item.query;
                  _performSearch(item.query);
                },
              );
            },
          ),
        ),
      ],
    );
  }
  
  Widget _buildResults() {
    if (_results == null) {
      return const SizedBox.shrink();
    }
    
    if (_results!.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.search_off, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              'No results for "${_searchController.text}"',
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }
    
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _results!.length,
      itemBuilder: (context, index) {
        final result = _results![index];
        return _SearchResultTile(result: result);
      },
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  final Map<String, dynamic> result;
  
  const _SearchResultTile({required this.result});
  
  @override
  Widget build(BuildContext context) {
    final title = result['title'] ?? 'Untitled';
    final sourceTitle = result['source_title'] ?? 'Unknown Source';
    final tradition = result['tradition'] ?? '';
    final content = result['content_plain'] ?? '';
    
    final preview = content.length > 150
        ? '${content.substring(0, 150)}...'
        : content;
    
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: ListTile(
        leading: const Icon(Icons.article),
        title: Text(
          title.isNotEmpty ? title : sourceTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$sourceTitle${tradition.isNotEmpty ? ' • $tradition' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _navigateToDetail(context),
      ),
    );
  }
  
  void _navigateToDetail(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ContentDetailScreen(
          contentId: result['id'],
        ),
      ),
    );
  }
}
