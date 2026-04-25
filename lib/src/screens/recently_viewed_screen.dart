import 'package:flutter/material.dart';

import '../services/recently_viewed_service.dart';
import 'content_detail_screen.dart';

class RecentlyViewedScreen extends StatefulWidget {
  const RecentlyViewedScreen({super.key});
  
  @override
  State<RecentlyViewedScreen> createState() => _RecentlyViewedScreenState();
}

class _RecentlyViewedScreenState extends State<RecentlyViewedScreen> {
  List<RecentlyViewedItem> _recent = [];
  bool _isLoading = true;
  
  final RecentlyViewedService _service = RecentlyViewedService();
  
  @override
  void initState() {
    super.initState();
    _loadRecent();
  }
  
  Future<void> _loadRecent() async {
    final recent = await _service.getRecent();
    if (mounted) {
      setState(() {
        _recent = recent;
        _isLoading = false;
      });
    }
  }
  
  Future<void> _clear() async {
    await _service.clear();
    _loadRecent();
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recently Viewed'),
        actions: [
          if (_recent.isNotEmpty)
            TextButton(
              onPressed: _clear,
              child: const Text('Clear'),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildContent(),
    );
  }
  
  Widget _buildContent() {
    if (_recent.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.history,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'No history yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Passages you view will appear here',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ),
      );
    }
    
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _recent.length,
      itemBuilder: (context, index) {
        final item = _recent[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: const Icon(Icons.article_outlined),
            title: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              item.source,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _navigateToContent(item.contentId),
          ),
        );
      },
    );
  }
  
  void _navigateToContent(int contentId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ContentDetailScreen(contentId: contentId),
      ),
    ).then((_) => _loadRecent());
  }
}
