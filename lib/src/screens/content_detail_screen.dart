import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../services/database_service.dart';

class ContentDetailScreen extends StatefulWidget {
  final int? sourceId;
  final int? contentId;
  
  const ContentDetailScreen({
    super.key,
    this.sourceId,
    this.contentId,
  });
  
  @override
  State<ContentDetailScreen> createState() => _ContentDetailScreenState();
}

class _ContentDetailScreenState extends State<ContentDetailScreen> {
  Map<String, dynamic>? _source;
  List<Map<String, dynamic>>? _contentUnits;
  Map<String, dynamic>? _singleContent;
  List<Map<String, dynamic>>? _tags;
  bool _isLoading = true;
  
  @override
  void initState() {
    super.initState();
    _loadContent();
  }
  
  Future<void> _loadContent() async {
    final dbService = context.read<DatabaseService>();
    
    if (widget.contentId != null) {
      // Load single content unit
      final content = await dbService.getContentUnit(widget.contentId!);
      if (content != null) {
        final tags = await dbService.getTagsForContent(widget.contentId!);
        setState(() {
          _singleContent = content;
          _tags = tags;
          _isLoading = false;
        });
      }
    } else if (widget.sourceId != null) {
      // Load all content for source
      final content = await dbService.getContentForSource(widget.sourceId!);
      // Also get source info
      // For now, just use content
      setState(() {
        _contentUnits = content;
        _isLoading = false;
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_getTitle()),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () {
              // TODO: Share content
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildContent(),
    );
  }
  
  String _getTitle() {
    if (_singleContent != null) {
      return _singleContent!['title'] ?? 'Content';
    }
    if (_source != null) {
      return _source!['title'] ?? 'Source';
    }
    return 'Content';
  }
  
  Widget _buildContent() {
    if (_singleContent != null) {
      return _buildSingleContent();
    }
    if (_contentUnits != null && _contentUnits!.isNotEmpty) {
      return _buildContentList();
    }
    return const Center(child: Text('No content found'));
  }
  
  Widget _buildSingleContent() {
    final content = _singleContent!;
    final title = content['title'] ?? '';
    final text = content['content'] ?? '';
    final unitType = content['unit_type'] ?? '';
    final unitNumber = content['unit_number'];
    
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          if (unitType.isNotEmpty || unitNumber != null)
            Text(
              '${_formatUnitType(unitType)}${unitNumber != null ? ' $unitNumber' : ''}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          if (title.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ],
          
          const SizedBox(height: 16),
          
          // Content
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: MarkdownBody(
                data: text,
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
        ],
      ),
    );
  }
  
  Widget _buildContentList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _contentUnits!.length,
      itemBuilder: (context, index) {
        final unit = _contentUnits![index];
        final title = unit['title'] ?? '';
        final unitType = unit['unit_type'] ?? '';
        final unitNumber = unit['unit_number'];
        final preview = _getPreview(unit['content'] ?? '');
        
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: CircleAvatar(
              child: Text('${index + 1}'),
            ),
            title: Text(
              title.isNotEmpty
                  ? title
                  : '${_formatUnitType(unitType)}${unitNumber != null ? ' $unitNumber' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _navigateToContent(unit['id']),
          ),
        );
      },
    );
  }
  
  String _getPreview(String text) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return cleaned.length > 100 ? '${cleaned.substring(0, 100)}...' : cleaned;
  }
  
  String _formatUnitType(String type) {
    switch (type) {
      case 'article':
        return 'Article';
      case 'qa':
        return 'Question';
      case 'section':
        return 'Section';
      case 'chapter':
        return 'Chapter';
      case 'canon':
        return 'Canon';
      default:
        return type[0].toUpperCase() + type.substring(1);
    }
  }
  
  void _navigateToContent(int contentId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ContentDetailScreen(contentId: contentId),
      ),
    );
  }
}