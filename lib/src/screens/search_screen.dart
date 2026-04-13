import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/database_service.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>>? _results;
  bool _isSearching = false;
  
  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
  
  Future<void> _performSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _results = null;
        _isSearching = false;
      });
      return;
    }
    
    setState(() {
      _isSearching = true;
    });
    
    final dbService = context.read<DatabaseService>();
    final results = await dbService.search(query.trim());
    
    if (mounted) {
      setState(() {
        _results = results;
        _isSearching = false;
      });
    }
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
              onChanged: (value) {
                // Trigger rebuild to show/hide clear button
                setState(() {});
              },
            ),
          ),
          
          // Results
          Expanded(
            child: _isSearching
                ? const Center(child: CircularProgressIndicator())
                : _buildResults(),
          ),
        ],
      ),
    );
  }
  
  Widget _buildResults() {
    if (_results == null) {
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
    
    // Truncate content for preview
    final preview = content.length > 150
        ? '${content.substring(0, 150)}...'
        : content;
    
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
    // Navigate to content detail screen
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

// Placeholder - will be replaced with actual import
class ContentDetailScreen extends StatelessWidget {
  final int contentId;
  
  const ContentDetailScreen({super.key, required this.contentId});
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Content')),
      body: const Center(child: Text('Content detail view')),
    );
  }
}