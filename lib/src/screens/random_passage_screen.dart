import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../services/database_service.dart';

class RandomPassageScreen extends StatefulWidget {
  const RandomPassageScreen({super.key});
  
  @override
  State<RandomPassageScreen> createState() => _RandomPassageScreenState();
}

class _RandomPassageScreenState extends State<RandomPassageScreen> {
  Map<String, dynamic>? _passage;
  List<Map<String, dynamic>>? _tags;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadRandomPassage();
  }
  
  Future<void> _loadRandomPassage() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final dbService = context.read<DatabaseService>();
      final content = await dbService.getRandomContentUnit();

      final tags = content == null
          ? null
          : await dbService.getTagsForContent(content['id'] as int);

      if (mounted) {
        setState(() {
          _passage = content ?? _passage;
          _tags = tags;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Random Passage'),
        actions: [
          IconButton(
            icon: const Icon(Icons.shuffle),
            onPressed: _loadRandomPassage,
            tooltip: 'Another passage',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _passage != null
              ? _buildPassage()
              : const Center(child: Text('Unable to load passage')),
    );
  }
  
  Widget _buildPassage() {
    final title = _passage!['title'] ?? 'Untitled';
    final content = _passage!['content'] ?? '';
    final source = _passage!['source_title'] ?? '';
    final tradition = _passage!['tradition'] ?? '';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title
          if (title.isNotEmpty) ...[
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
          ],

          // Attribution
          if (source.isNotEmpty) ...[
            Text(
              '$source${tradition.isNotEmpty ? ' • $tradition' : ''}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
          const SizedBox(height: 16),
          
          // Content
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: MarkdownBody(
                data: content,
                styleSheet: MarkdownStyleSheet(
                  p: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ),
          ),
          
          // Tags
          if (_tags != null && _tags!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Topics',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _tags!.map((tag) {
                return Chip(
                  label: Text(tag['name'] ?? ''),
                  visualDensity: VisualDensity.compact,
                );
              }).toList(),
            ),
          ],
          
          const SizedBox(height: 32),
          
          // Action buttons
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _loadRandomPassage,
                  icon: const Icon(Icons.shuffle),
                  label: const Text('Next Passage'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
