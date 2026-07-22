import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../services/packs/pack_catalogue.dart';
import '../services/packs/pack_provider.dart';
import 'library_screen.dart';
import '../services/database_service.dart';
import '../services/ollama_service.dart';
import '../services/settings_provider.dart';
import '../services/inference/inference_backend.dart';
import '../services/inference/inference_provider.dart';
import 'content_detail_screen.dart';

// ContextPassage is defined in ollama_service.dart

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];

  /// Collections that would have helped with the most recent question but are
  /// not installed. Shown above the composer rather than inside the answer, so
  /// it reads as a note about the library rather than part of what the sources
  /// say.
  List<PackSuggestion> _gaps = const [];
  bool _isLoading = false;

  /// Set by the stop button; the streaming loop checks it between chunks.
  bool _cancelled = false;

  late final DatabaseService _databaseService;

  @override
  void initState() {
    super.initState();
    // The database is opened once at startup and shared via Provider —
    // constructing a second service here would re-run the asset copy and open
    // a duplicate handle.
    _databaseService = context.read<DatabaseService>();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => context.read<InferenceProvider>().refreshStatus(),
    );
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
  
  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isLoading) return;

    final backend = context.read<InferenceProvider>().backend;

    setState(() {
      _messages.add(ChatMessage(
        text: text,
        isUser: true,
        timestamp: DateTime.now(),
      ));
      _isLoading = true;
      _cancelled = false;
    });

    _messageController.clear();
    _scrollToBottom();

    // Worked out before retrieval runs, from the question rather than from
    // its results: the whole point is to describe sources that are *absent*,
    // which by definition cannot appear in what was retrieved.
    _gaps = context.read<PackProvider>().coverageGapsFor(
          text,
          _databaseService.extractTags(text),
        );

    try {
      final passages = await _databaseService.searchForRAG(text, limit: 6);

      if (passages.isEmpty) {
        _addAssistantMessage(
          "I couldn't find anything in the library for that. Try different "
          'wording, or browse by tradition.',
        );
        return;
      }

      final sources = passages
          .map((p) => Citation(
                contentId: p['id'] as int,
                source: p['source_title'] as String? ?? 'Unknown source',
                author: p['source_author'] as String?,
                tradition: p['tradition'] as String?,
                sourceUrl: p['source_url'] as String?,
              ))
          .toList();

      // Search-only mode: the retrieved passages *are* the answer.
      if (backend is RetrievalOnlyBackend) {
        _addAssistantMessage(
          'Search-only mode is on, so no answer is generated. '
          'These ${sources.length} passages matched your question:',
          citations: sources,
        );
        return;
      }

      final status = await backend.checkStatus();
      if (!status.available) {
        _addAssistantMessage(status.detail ?? 'That backend is unavailable.');
        return;
      }

      await _streamAnswer(backend, text, passages, sources);
    } catch (e) {
      if (mounted) _addAssistantMessage('Error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Build the RAG prompt and stream the answer into a placeholder message.
  Future<void> _streamAnswer(
    InferenceBackend backend,
    String question,
    List<Map<String, dynamic>> passages,
    List<Citation> sources,
  ) async {
    // Spend the backend's context budget across the retrieved passages rather
    // than using one fixed size for every backend — an on-device model and a
    // cloud model differ by an order of magnitude here.
    final perPassage =
        (backend.contextBudgetChars / passages.length).floor().clamp(400, 8000);

    final context = StringBuffer()..writeln('Relevant sources:\n');
    for (var i = 0; i < passages.length; i++) {
      final content = passages[i]['content'] as String? ?? '';
      context
        ..writeln('[${i + 1}] ${sources[i].promptLabel}')
        ..writeln(content.length > perPassage
            ? '${content.substring(0, perPassage).trimRight()}… [truncated]'
            : content)
        ..writeln();
    }

    final prompt = '$context\nUser question: $question\n\n'
        'Answer using the provided sources. Cite them as [1], [2] and so on.';

    final index = _messages.length;
    setState(() {
      _messages.add(ChatMessage(
        text: '',
        isUser: false,
        timestamp: DateTime.now(),
        citations: sources,
      ));
    });

    final buffer = StringBuffer();
    await for (final chunk in backend.generate(
      prompt: prompt,
      system: OllamaService().buildSystemPrompt(),
    )) {
      if (_cancelled || !mounted) break;
      buffer.write(chunk);
      setState(() {
        _messages[index] = ChatMessage(
          text: buffer.toString(),
          isUser: false,
          timestamp: _messages[index].timestamp,
          citations: sources,
        );
      });
      _scrollToBottom();
    }

    if (_cancelled && mounted && buffer.isNotEmpty) {
      setState(() {
        _messages[index] = ChatMessage(
          text: '${buffer.toString()}\n\n_(stopped)_',
          isUser: false,
          timestamp: _messages[index].timestamp,
          citations: sources,
        );
      });
    }
  }

  void _addAssistantMessage(String text, {List<Citation>? citations}) {
    setState(() {
      _messages.add(ChatMessage(
        text: text,
        isUser: false,
        timestamp: DateTime.now(),
        citations: citations,
      ));
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ask AI'),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showInfo(context),
          ),
        ],
      ),
      body: Column(
        children: [
          // Messages list
          Expanded(
            child: _messages.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      return _MessageBubble(message: _messages[index]);
                    },
                  ),
          ),
          
          if (_gaps.isNotEmpty && !_isLoading) _CoverageNotice(gaps: _gaps),

          // Loading indicator
          if (_isLoading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Text(_cancelled ? 'Stopping…' : 'Thinking…'),
                  const Spacer(),
                  // Local models can take a long time; let the user bail out.
                  TextButton.icon(
                    onPressed: _cancelled
                        ? null
                        : () => setState(() => _cancelled = true),
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    label: const Text('Stop'),
                  ),
                ],
              ),
            ),
          
          // Input area
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 4,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: InputDecoration(
                        hintText: 'Ask a theological question...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      maxLines: null,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    icon: const Icon(Icons.send),
                    onPressed: _isLoading ? null : _sendMessage,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            'Ask a theological question',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Query the database with AI assistance',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _SuggestionChip('What is the Trinity?', onTap: (text) => _submitSuggestion(text)),
              _SuggestionChip('Compare views on baptism', onTap: (text) => _submitSuggestion(text)),
              _SuggestionChip('What did Augustine say about grace?', onTap: (text) => _submitSuggestion(text)),
              _SuggestionChip('Explain the Nicene Creed', onTap: (text) => _submitSuggestion(text)),
            ],
          ),
        ],
      ),
    );
  }
  
  void _submitSuggestion(String text) {
    _messageController.text = text;
    _sendMessage();
  }
  
  void _showInfo(BuildContext context) {
    final inference = context.read<InferenceProvider>();
    final backend = inference.backend;
    final status = inference.status;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('AI backend'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    status?.available == true
                        ? Icons.check_circle
                        : Icons.error_outline,
                    color: status?.available == true
                        ? Colors.green
                        : Colors.orange,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      backend.displayName,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              if (status?.detail != null) ...[
                const SizedBox(height: 8),
                Text(status!.detail!),
              ],
              const SizedBox(height: 16),
              Text(backend.description),
              const SizedBox(height: 16),

              // State the privacy position per backend rather than making a
              // blanket claim: with a cloud key, data does leave the device.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    backend.isPrivate ? Icons.lock_outline : Icons.cloud_upload,
                    size: 18,
                    color: backend.isPrivate
                        ? Colors.green
                        : Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      backend.isPrivate
                          ? 'Your questions and the library stay on your device.'
                          : 'Your question and the retrieved passages are sent '
                              "to this provider, under that provider's privacy "
                              'policy and retention terms rather than this '
                              "app's. They may be retained or used for "
                              'training — check their terms.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// One cited passage, showing which tradition it speaks for and whether its
/// text can be traced to a published source.
///
/// Replaces a row of bare title chips. Those were honest about *what* was
/// quoted and silent about everything that makes a quotation checkable — which
/// tradition it represents, who wrote it, and whether anyone can go and read
/// the original.
class _CitationTile extends StatelessWidget {
  final int index;
  final Citation citation;

  const _CitationTile({required this.index, required this.citation});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ContentDetailScreen(contentId: citation.contentId),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 22,
              child: Text('[$index]',
                  style: text.labelSmall?.copyWith(color: scheme.primary)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(citation.source,
                      style: text.bodySmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Wrap(
                    spacing: 6,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (citation.tradition != null &&
                          citation.tradition!.isNotEmpty)
                        _Badge(
                          label: citation.tradition!,
                          background: scheme.secondaryContainer,
                          foreground: scheme.onSecondaryContainer,
                        ),
                      if (citation.author != null &&
                          citation.author!.isNotEmpty)
                        Text(citation.author!,
                            style: text.labelSmall
                                ?.copyWith(color: scheme.onSurfaceVariant)),
                      if (!citation.isTraceable)
                        // Said plainly rather than hidden. A reader comparing
                        // traditions is entitled to know which quotations they
                        // can go and check and which they cannot.
                        _Badge(
                          label: 'origin not recorded',
                          background: scheme.errorContainer,
                          foreground: scheme.onErrorContainer,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: scheme.outline),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color background;
  final Color foreground;

  const _Badge({
    required this.label,
    required this.background,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: foreground, fontSize: 10),
      ),
    );
  }
}

/// Tells the reader that the answer they just received was drawn from a
/// fraction of the available sources.
///
/// This exists because splitting the corpus made a new failure reachable: the
/// app can only search text it holds, so a library without the fathers answers
/// a question about the Eucharist from confessions alone — fluent, cited, and
/// drawn from under a tenth of what has been written. For an app whose purpose
/// is showing what each tradition actually taught, omitting one silently is
/// the worst thing it could do.
class _CoverageNotice extends StatelessWidget {
  final List<PackSuggestion> gaps;

  const _CoverageNotice({required this.gaps});

  @override
  Widget build(BuildContext context) {
    final packs = context.read<PackProvider>();
    final scheme = Theme.of(context).colorScheme;
    final gap = gaps.first;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  gap.explanation,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 2),
                Text(
                  'This answer draws only on what you have installed.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LibraryScreen()),
            ),
            child: Text('Add ${packs.nameOf(gap.packId)}'),
          ),
        ],
      ),
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  final String text;
  final Function(String)? onTap;
  
  const _SuggestionChip(this.text, {this.onTap});
  
  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(text),
      onPressed: () {
        if (onTap != null) {
          onTap!(text);
        }
      },
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  
  const _MessageBubble({required this.message});
  
  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        decoration: BoxDecoration(
          color: isUser
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isUser)
              Text(message.text)
            else
              MarkdownBody(
                data: message.text,
              ),
            
            if (context.watch<SettingsProvider>().showCitations &&
                message.citations != null &&
                message.citations!.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 8),
              Text(
                'Sources:',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: 4),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: message.citations!
                    .asMap()
                    .entries
                    .map((entry) => _CitationTile(
                          index: entry.key + 1,
                          citation: entry.value,
                        ))
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A cited passage. Carries the content unit id so the citation can be opened
/// — a citation the reader cannot follow is not much of a citation.
/// A passage the answer was built from, described well enough to check.
///
/// Tradition is carried because it is the point of the app: an answer about
/// baptism drawn entirely from Reformed confessions is a different claim from
/// one spanning four traditions, and until now the citations looked identical
/// either way.
///
/// [sourceUrl] is carried for the same reason in the other direction. The
/// corpus holds both editions traced to a published text and legacy entries
/// with no recorded origin, and showing them the same way asserts a confidence
/// the second kind has not earned.
class Citation {
  final int contentId;
  final String source;
  final String? author;
  final String? tradition;
  final String? sourceUrl;

  const Citation({
    required this.contentId,
    required this.source,
    this.author,
    this.tradition,
    this.sourceUrl,
  });

  bool get isTraceable => sourceUrl != null && sourceUrl!.isNotEmpty;

  /// How the passage is described to the model, as opposed to to the reader.
  ///
  /// The tradition is included deliberately: a comparative question is exactly
  /// the case where the model needs to know which camp a passage speaks for,
  /// and without it the answer attributes positions by guesswork.
  String get promptLabel {
    final parts = [
      source,
      if (author != null && author!.isNotEmpty) author!,
      if (tradition != null && tradition!.isNotEmpty) '$tradition tradition',
    ];
    return parts.join(' — ');
  }
}

class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final List<Citation>? citations;
  
  ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.citations,
  });
}