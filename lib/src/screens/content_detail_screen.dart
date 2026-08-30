import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../reader/passage_reader.dart';
import '../services/database_service.dart';
import '../services/bookmark_service.dart';
import 'source_reader_screen.dart';

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
  bool _isBookmarked = false;
  
  late final BookmarkService _bookmarkService;
  
  @override
  void initState() {
    super.initState();
    _bookmarkService = BookmarkService();
    _loadContent();
  }
  
  Future<void> _checkBookmarkStatus() async {
    if (widget.contentId != null) {
      final isBookmarked = await _bookmarkService.isBookmarked(widget.contentId!);
      if (mounted) {
        setState(() {
          _isBookmarked = isBookmarked;
        });
      }
    }
  }
  
  Future<void> _loadContent() async {
    final dbService = context.read<DatabaseService>();
    
    if (widget.contentId != null) {
      // Load single content unit
      final content = await dbService.getContentUnit(widget.contentId!);

      // A bookmark or recently-viewed entry can outlive the passage it points
      // at — corpus pruning removes units. Fall through to the missing state
      // rather than leaving the spinner up forever.
      if (content == null) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      final tags = await dbService.getTagsForContent(widget.contentId!);
      if (!mounted) return;
      setState(() {
        _singleContent = content;
        _tags = tags;
        _isLoading = false;
      });
      _checkBookmarkStatus();
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
            icon: Icon(_isBookmarked ? Icons.bookmark : Icons.bookmark_outline),
            onPressed: _toggleBookmark,
          ),
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _shareContent,
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
    return _buildMissing();
  }
  
  Widget _buildMissing() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'This passage is no longer available',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'It may have been removed from the library. '
              'Saved links to it can be deleted.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
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
          
          const SizedBox(height: 12),
          _Provenance(content: content),

          if (content['source_id'] is int) ...[
            const SizedBox(height: 8),
            _ReadInContext(
              onTap: () => _openInSource(content['source_id'] as int,
                  content['source_title'] as String?),
            ),
          ],

          const SizedBox(height: 16),

          // Content. Tappable by verse or paragraph, like the reader — a
          // passage reached from a search result or a citation should be able
          // to be marked up in the same way as one reached by reading to it.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: PassageReader(
                key: ValueKey(widget.contentId),
                contentUnitId: widget.contentId!,
                content: text,
                unitTitle: title.isNotEmpty ? title : null,
                sourceTitle: content['source_title'] as String?,
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(height: 1.6),
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
  
  void _toggleBookmark() async {
    if (widget.contentId == null || _singleContent == null) return;
    
    final content = _singleContent!;
    final title = content['title'] ?? 'Untitled';
    final source = content['source_title'] ?? 'Unknown Source';
    final preview = _getPreview(content['content'] ?? '');
    
    final isNowBookmarked = await _bookmarkService.toggleBookmark(
      contentId: widget.contentId!,
      title: title,
      source: source,
      preview: preview,
    );
    
    if (mounted) {
      setState(() {
        _isBookmarked = isNowBookmarked;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isNowBookmarked ? 'Added to bookmarks' : 'Removed from bookmarks'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }
  
  void _shareContent() {
    if (_singleContent == null) return;
    
    final title = _singleContent!['title'] ?? '';
    final text = _singleContent!['content'] ?? '';
    final source = _singleContent!['source_title'] ?? 'Unknown Source';
    
    final shareText = '''$title

$text

— $source

Shared from Council app'''.trim();
    
    // On web/mobile, copy to clipboard
    Clipboard.setData(ClipboardData(text: shareText));
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Copied to clipboard'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }
  
  /// Open the whole work, at this passage.
  ///
  /// A citation shows what was quoted; the objection to a quotation is almost
  /// always about what surrounds it. The reader lands on this very section
  /// rather than on the work's first page, with the pager ready to move either
  /// way through it.
  void _openInSource(int sourceId, String? sourceTitle) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SourceReaderScreen(
          sourceId: sourceId,
          // 71 units carry a source_id with no row in `sources`, so the title
          // can genuinely be missing. The work is still readable straight
          // through; only its name is unknown.
          title: (sourceTitle?.isNotEmpty ?? false) ? sourceTitle! : 'Source',
          initialUnitId: widget.contentId,
        ),
      ),
    );
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

/// The way out of the citation and into the work it was taken from.
///
/// Sits directly under the provenance card because it answers the question
/// that card raises: having been told where a passage comes from, the next
/// thing wanted is to see it there. Deliberately an ordinary tappable row and
/// not a link on the source's name — the name in the card is being read as
/// evidence, and evidence that moves when touched is harder to read.
class _ReadInContext extends StatelessWidget {
  final VoidCallback onTap;

  const _ReadInContext({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.menu_book_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Read in context',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

/// Where this text came from.
///
/// The detail screen is where someone lands when they want to check a
/// citation, so it is where the corpus has to be honest about what it knows.
/// Most sources here name a published edition and a URL; a handful are legacy
/// entries whose text is genuine but whose origin was never recorded, and
/// those cannot be verified by anyone. Presenting both identically would
/// quietly borrow the credibility of the first for the second.
class _Provenance extends StatelessWidget {
  final Map<String, dynamic> content;

  const _Provenance({required this.content});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final source = content['source_title'] as String?;
    final author = content['source_author'] as String?;
    final tradition = content['tradition'] as String?;
    final date = content['date_composed'] as String?;
    final url = content['source_url'] as String?;
    final licence = content['license'] as String?;
    final traceable = url != null && url.isNotEmpty;

    final facts = [
      if (author != null && author.isNotEmpty) author,
      if (date != null && date.isNotEmpty) date,
      if (licence != null && licence.isNotEmpty) licence,
    ].join(' · ');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (tradition != null && tradition.isNotEmpty) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(tradition,
                      style: text.labelSmall
                          ?.copyWith(color: scheme.onSecondaryContainer)),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(source ?? 'Unknown source',
                    style:
                        text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          if (facts.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(facts,
                style:
                    text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                traceable ? Icons.link : Icons.help_outline,
                size: 14,
                color: traceable ? scheme.onSurfaceVariant : scheme.error,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: traceable
                    ? SelectableText(
                        url,
                        style: text.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      )
                    : Text(
                        'The origin of this text was never recorded, so it '
                        'cannot be checked against a published edition.',
                        style:
                            text.labelSmall?.copyWith(color: scheme.error),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
