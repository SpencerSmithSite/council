import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../services/packs/pack_catalogue.dart';
import '../services/packs/pack_manifest.dart';
import '../services/packs/pack_provider.dart';
import 'library_screen.dart';
import '../services/chat_history_service.dart';
import '../services/database_service.dart';
import '../services/ollama_service.dart';
import '../services/settings_provider.dart';
import '../services/inference/inference_backend.dart';
import '../services/inference/inference_provider.dart';
import 'content_detail_screen.dart';
import '../theme/glass.dart';
import '../theme/glass_controls.dart';

// ContextPassage is defined in ollama_service.dart

class ChatScreen extends StatefulWidget {
  /// Pushed as its own route — from a passage, or from the history list —
  /// rather than living in the Ask tab, so it needs a bar with a way back.
  final bool standalone;

  /// A passage the reader selected and wants to ask about. The conversation is
  /// anchored to it: it leads the prompt, and it is stored with the thread so
  /// reopening it later still shows what "this" was.
  final PinnedPassage? passage;

  /// An existing conversation to reopen. When null, the Ask tab resumes the
  /// most recent one and a standalone screen starts a fresh thread.
  final int? conversationId;

  const ChatScreen({
    super.key,
    this.standalone = false,
    this.passage,
    this.conversationId,
  });

  @override
  State<ChatScreen> createState() => ChatScreenState();
}

class ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];

  final ChatHistoryService _history = ChatHistoryService();

  /// The thread being written to. Created on the first message rather than on
  /// open, so glancing at Ask and leaving does not litter the history.
  Conversation? _conversation;

  /// The passage this thread is about — from the widget, or restored from a
  /// conversation that was opened from the history list.
  PinnedPassage? _passage;

  bool _restoring = true;

  /// Collections that would have helped with the most recent question but are
  /// not installed. Shown above the composer rather than inside the answer, so
  /// it reads as a note about the library rather than part of what the sources
  /// say.
  List<PackSuggestion> _gaps = const [];

  /// The question the current gap relates to, so it can be re-answered.
  String? _gapQuestion;
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
    _passage = widget.passage;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => context.read<InferenceProvider>().refreshStatus(),
    );
    _restore();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Put back whatever thread this screen should be showing.
  ///
  /// The Ask tab reopens the most recent conversation, because a research
  /// session that survives closing the app is the whole point of keeping
  /// history at all. A screen opened from a selected passage always starts
  /// fresh — the reader asked about *this* verse, not about whatever they were
  /// discussing last week.
  Future<void> _restore() async {
    Conversation? conversation;
    if (widget.conversationId != null) {
      conversation = await _history.conversation(widget.conversationId!);
    } else if (!widget.standalone && widget.passage == null) {
      conversation = await _history.mostRecent();
    }

    if (conversation == null) {
      if (mounted) setState(() => _restoring = false);
      return;
    }

    final stored = await _history.messages(conversation.id);
    if (!mounted) return;
    setState(() {
      _conversation = conversation;
      _passage ??= conversation?.passage;
      _messages
        ..clear()
        ..addAll(stored.map(ChatMessage.fromStored));
      _restoring = false;
    });
    _scrollToBottom();
  }

  /// Begin a new thread, keeping the old one in the history.
  ///
  /// Public because the main screen's compose button drives it.
  Future<void> startNewConversation() async {
    final previous = _conversation;
    setState(() {
      _messages.clear();
      _conversation = null;
      _passage = widget.passage;
      _gaps = const [];
      _gapQuestion = null;
    });
    if (previous != null) await _history.deleteIfEmpty(previous.id);
  }

  /// Show an existing thread in this screen. Used by the history list, which
  /// hands its selection back to the Ask tab rather than opening a second copy
  /// of the same conversation somewhere else.
  Future<void> openConversation(int id) async {
    final conversation = await _history.conversation(id);
    if (conversation == null) return;
    final stored = await _history.messages(id);
    if (!mounted) return;
    setState(() {
      _conversation = conversation;
      _passage = conversation.passage;
      _messages
        ..clear()
        ..addAll(stored.map(ChatMessage.fromStored));
      _gaps = const [];
      _gapQuestion = null;
      _restoring = false;
    });
    _scrollToBottom();
  }

  /// The thread to write to, created if this is the first message in it.
  Future<Conversation> _ensureConversation(String firstQuestion) async {
    final existing = _conversation;
    if (existing != null) return existing;

    final created = await _history.createConversation(
      passage: _passage,
      // Named after the passage when there is one, so a list of threads about
      // different verses can be told apart before any of them is opened.
      title: _passage != null && _passage!.reference.isNotEmpty
          ? _passage!.reference
          : 'New conversation',
    );
    if (mounted) setState(() => _conversation = created);
    _conversation = created;
    if (_passage == null) {
      await _history.retitleIfUnnamed(created.id, firstQuestion);
    }
    return created;
  }

  Future<void> _sendMessage({String? question}) async {
    final text = question ?? _messageController.text.trim();
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
    // which by definition cannot appear in what was retrieved. Read from the
    // provider before the first await, so nothing here touches a context that
    // may have been disposed in the meantime.
    _gaps = context.read<PackProvider>().coverageGapsFor(
          text,
          _databaseService.extractTags(text),
        );
    // Kept so the question can be asked again once the missing collection
    // arrives. Telling someone their answer was incomplete and then making
    // them retype the question is most of a feature.
    _gapQuestion = _gaps.isEmpty ? null : text;

    final conversation = await _ensureConversation(text);
    await _history.addMessage(
      conversationId: conversation.id,
      isUser: true,
      text: text,
    );

    try {
      final retrieved = await _databaseService.searchForRAG(text, limit: 6);

      // The selected passage leads, ahead of anything retrieval found. The
      // reader is asking about *that* text, so it is the source the answer has
      // to be about; the rest is context brought in to interpret it.
      final passages = [
        if (_passage != null) _pinnedAsPassage(_passage!),
        ...retrieved,
      ];

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
      if (mounted) _addAssistantMessage(_friendlyError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// The selected passage shaped like a retrieved one, so it can travel
  /// through the same prompt-building and citation code as everything else.
  ///
  /// It carries no `source_url`, which is not an oversight: the citation tile
  /// reads a missing URL as "origin not recorded", and for a passage quoted out
  /// of the reader's own screen that is exactly right — the traceable thing is
  /// the unit it came from, which the citation links to.
  Map<String, dynamic> _pinnedAsPassage(PinnedPassage passage) => {
        'id': passage.contentUnitId,
        'content': passage.quote,
        'source_title': passage.sourceTitle ?? passage.reference,
        'source_author': null,
        'tradition': null,
        'source_url': null,
      };

  /// Turn a raw exception into something a reader can act on. A dropped
  /// connection almost always means the model was still loading when the
  /// request went out (the retry inside the backend has already been exhausted
  /// by this point), so say that rather than surfacing a socket error.
  String _friendlyError(Object e) {
    final s = e.toString().toLowerCase();
    const connectionSignals = [
      'connection abort',
      'connection reset',
      'connection closed',
      'connection terminated',
      'software caused',
      'socketexception',
      'connection refused',
    ];
    if (connectionSignals.any(s.contains)) {
      return "The model didn't respond in time — it may still be loading. "
          'Give it a moment and ask again.';
    }
    return 'Error: $e';
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

    // When the reader selected a passage, say so plainly. Without it the model
    // is handed several sources of equal standing and answers about the topic
    // rather than about the text in front of the person asking.
    final anchor = _passage == null
        ? ''
        : 'The reader is reading ${_passage!.promptLabel}, quoted as source '
            '[1], and their question is about it. Answer about that passage '
            'first, using the other sources to illuminate it.\n\n';

    final prompt = '$context\n${anchor}User question: $question\n\n'
        'Answer using the provided sources. Cite them as [1], [2] and so on.';

    final index = _messages.length;
    setState(() {
      _messages.add(ChatMessage(
        text: '',
        isUser: false,
        timestamp: DateTime.now(),
        citations: sources,
        generated: true,
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
          generated: true,
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
          generated: true,
        );
      });
    }

    // Written once, at the end, rather than on every chunk: a token-by-token
    // update would put thousands of writes behind a single answer. A stopped
    // answer is stored too — the reader stopped it because they had read
    // enough, not because they wanted it thrown away.
    await _persist(index);
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
    _persist(_messages.length - 1);
  }

  /// Which message carries the "a model wrote this" caveat: the first one in
  /// the thread that a model actually wrote.
  ///
  /// Derived from the transcript rather than tracked in a flag, so it lands in
  /// the same place when a conversation is reopened from the history weeks
  /// later as it did when the answer first arrived.
  int get _disclaimerIndex =>
      _messages.indexWhere((m) => !m.isUser && m.generated);

  /// Store the message at [index], if there is a conversation to store it in.
  Future<void> _persist(int index) async {
    final conversation = _conversation;
    if (conversation == null || index >= _messages.length) return;
    final message = _messages[index];
    if (message.text.isEmpty) return;

    await _history.addMessage(
      conversationId: conversation.id,
      isUser: message.isUser,
      text: message.text,
      generated: message.generated,
      citations: [for (final c in message.citations ?? const []) c.toJson()],
    );
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
    // Full-bleed content, with the top inset clearing the floating menu and
    // settings bubbles the chrome hovers over it. A standalone screen has a
    // real app bar instead, so it needs none of that.
    final topInset =
        widget.standalone ? 12.0 : MediaQuery.of(context).padding.top + 56;

    return Scaffold(
      backgroundColor: widget.standalone ? null : Colors.transparent,
      appBar: widget.standalone
          ? AppBar(
              title: Text(
                _passage?.reference.isNotEmpty == true
                    ? _passage!.reference
                    : _conversation?.title ?? 'Ask',
                overflow: TextOverflow.ellipsis,
              ),
            )
          : null,
      // The composer floats over the transcript rather than standing on it, so
      // the last answer passes behind the glass instead of being cut off at it.
      extendBody: true,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Both of these belong to the composer rather than to the transcript:
          // they are about the question being asked, not about what has already
          // been said, and they travel with the bar when the keyboard lifts it.
          if (_gaps.isNotEmpty && !_isLoading)
            _CoverageNotice(
              gaps: _gaps,
              onInstalled: () {
                final question = _gapQuestion;
                setState(() {
                  _gaps = const [];
                  _gapQuestion = null;
                });
                if (question != null) _sendMessage(question: question);
              },
            ),

          if (_isLoading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
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
                  TextButton(
                    onPressed: _cancelled
                        ? null
                        : () => setState(() => _cancelled = true),
                    child: const Text('Stop'),
                  ),
                ],
              ),
            ),

          GlassComposer(
            controller: _messageController,
            hintText: _passage == null
                ? 'Ask a theological question…'
                : 'Ask about this passage…',
            enabled: !_isLoading,
            trailingIcon: AppIcons.send,
            onSubmit: () => _sendMessage(),
          ),
        ],
      ),
      body: Builder(
        // Inside the body, so the MediaQuery carrying the composer's height is
        // the one in scope. See [floatingBottomInset].
        builder: (context) => Column(
          children: [
            if (_passage != null) _PassageBanner(passage: _passage!),
            Expanded(
              child: _restoring
                  ? const SizedBox.shrink()
                  : _messages.isEmpty
                      ? _buildEmptyState(context)
                      : ListView.builder(
                          controller: _scrollController,
                          // Dragging the transcript puts the keyboard away. On
                          // iOS there is otherwise no gesture that does, and a
                          // multi-line composer's return key inserts rather than
                          // dismisses — so the keyboard could sit there taking
                          // half the screen with nothing to tap.
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: EdgeInsets.fromLTRB(
                            16,
                            topInset,
                            16,
                            floatingBottomInset(context),
                          ),
                          itemCount: _messages.length,
                          itemBuilder: (context, index) {
                            return _MessageBubble(
                              message: _messages[index],
                              // Said once per thread, under the first answer a
                              // model actually wrote. On every answer it becomes
                              // furniture people stop reading; never is worse.
                              showsDisclaimer: index == _disclaimerIndex,
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  /// The opening screen. With a passage selected the prompts are about *it*,
  /// because a reader who has just tapped three verses and pressed the sparkle
  /// has a question about those verses, not about the Nicene Creed.
  /// [context] must come from inside the scaffold body: the prompts are centred
  /// in the space the composer leaves, not in the whole screen, or they sit
  /// behind it.
  Widget _buildEmptyState(BuildContext context) {
    final anchored = _passage != null;
    final suggestions = anchored
        ? const [
            'What does this passage mean?',
            'What is the historical context?',
            'How have different traditions read this?',
            'Where else does Scripture say this?',
          ]
        : const [
            'What is the Trinity?',
            'Compare views on baptism',
            'What did Augustine say about grace?',
            'Explain the Nicene Creed',
          ];

    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, 0, 24, floatingBottomInset(context)),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              anchored ? Icons.auto_awesome : Icons.chat_bubble_outline,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              anchored
                  ? 'Ask about what you selected'
                  : 'Ask a theological question',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              anchored
                  ? 'Answered from this passage and the rest of your library.'
                  : 'Query the database with AI assistance',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final suggestion in suggestions)
                  _SuggestionChip(suggestion, onTap: _submitSuggestion),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  void _submitSuggestion(String text) {
    _messageController.text = text;
    _sendMessage();
  }
  
}

/// The passage a conversation is about, kept in view above it.
///
/// Pinned rather than folded into the first message, because the reader will
/// ask several questions in a row and the text has to still be there for the
/// third one. Collapsed to three lines: it is a reminder of what is being
/// discussed, not the reading surface.
class _PassageBanner extends StatelessWidget {
  final PinnedPassage passage;

  const _PassageBanner({required this.passage});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.format_quote, size: 14, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  [
                    if (passage.reference.isNotEmpty) passage.reference,
                    if ((passage.sourceTitle ?? '').isNotEmpty)
                      passage.sourceTitle!,
                  ].join(' · '),
                  style: text.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              InkWell(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        ContentDetailScreen(contentId: passage.contentUnitId),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text('Open',
                      style: text.labelSmall?.copyWith(color: scheme.primary)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            passage.quote,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: text.bodySmall?.copyWith(height: 1.4),
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
/// fraction of the available sources — and closes the gap in place.
///
/// This exists because splitting the corpus made a new failure reachable: the
/// app can only search text it holds, so a library without the fathers answers
/// a question about the Eucharist from confessions alone — fluent, cited, and
/// drawn from under a tenth of what has been written on it.
///
/// It downloads here rather than linking to the Library. Sending someone to
/// another screen to fix a problem they did not know they had, and expecting
/// them to come back and retype the question, is most of a feature: the answer
/// is the point, and it should arrive on its own once the collection lands.
class _CoverageNotice extends StatefulWidget {
  final List<PackSuggestion> gaps;

  /// Called once the missing collection is installed, so the question that
  /// prompted the notice can be answered again.
  final VoidCallback onInstalled;

  const _CoverageNotice({required this.gaps, required this.onInstalled});

  @override
  State<_CoverageNotice> createState() => _CoverageNoticeState();
}

class _CoverageNoticeState extends State<_CoverageNotice> {
  bool _busy = false;
  String? _error;

  PackSuggestion get _gap => widget.gaps.first;

  /// The collection to install, if the catalogue has been fetched.
  ///
  /// It may not have been. The notice is built from a catalogue bundled with
  /// the app precisely so it works offline, while the manifest is a separate
  /// network call — so the gap can always be described even when the fix
  /// cannot yet be offered.
  Collection? _collection(PackProvider packs) {
    final manifest = packs.manifest;
    if (manifest == null) return null;
    for (final collection in manifest.collections) {
      if (collection.id == _gap.packId) return collection;
    }
    return null;
  }

  Future<void> _install() async {
    final packs = context.read<PackProvider>();
    setState(() {
      _busy = true;
      _error = null;
    });

    // Fetch the catalogue if this is the first time it has been needed.
    if (packs.manifest == null) await packs.refresh();
    if (!mounted) return;

    final collection = _collection(packs);
    if (collection == null) {
      setState(() {
        _busy = false;
        _error = 'That collection could not be reached.';
      });
      return;
    }

    await packs.install(collection);
    if (!mounted) return;

    if (packs.error != null) {
      setState(() {
        _busy = false;
        _error = packs.error;
      });
      return;
    }
    widget.onInstalled();
  }

  @override
  Widget build(BuildContext context) {
    final packs = context.watch<PackProvider>();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final collection = _collection(packs);
    final size = collection == null ? null : packs.bytesToInstall(collection);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_gap.explanation, style: text.bodySmall),
                    const SizedBox(height: 2),
                    Text(
                      'This answer draws only on what you have installed.',
                      style: text.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 4),
                      Text(_error!,
                          style: text.bodySmall?.copyWith(color: scheme.error)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: packs.progress > 0 ? packs.progress : null,
            ),
            const SizedBox(height: 6),
            Text(
              'Downloading — your question will be answered again '
              'automatically.',
              style: text.labelSmall,
            ),
          ] else
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const LibraryScreen()),
                    ),
                    child: const Text('Browse library'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton.tonal(
                    onPressed: _install,
                    // The size is shown on the button because this is an
                    // unsolicited suggestion to spend someone's data.
                    child: Text(
                      size == null
                          ? 'Add ${packs.nameOf(_gap.packId)}'
                          : 'Add ${packs.nameOf(_gap.packId)} · '
                              '${formatBytes(size)}',
                    ),
                  ),
                ],
              ),
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

  /// Whether this message carries the once-per-thread reliability caveat.
  final bool showsDisclaimer;

  const _MessageBubble({required this.message, this.showsDisclaimer = false});

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;

    final bubble = Align(
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

    if (!showsDisclaimer) return bubble;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [bubble, const _ModelCaveat()],
    );
  }
}

/// Said once per conversation, under the first answer a model wrote.
///
/// The app's whole claim is that an answer can be checked, and the citations
/// under every answer are what make that possible — so this points at them
/// rather than being a generic disclaimer. Stated once and quietly: a warning
/// repeated under every answer stops being read, which leaves the app both
/// noisier and no more honest.
class _ModelCaveat extends StatelessWidget {
  const _ModelCaveat();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8, right: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 13, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Answers are written by a language model and can be wrong or '
              'misattributed. Check them against the sources cited.',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.35,
                  ),
            ),
          ),
        ],
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

  /// Stored alongside the message it belongs to, so a reopened conversation
  /// still shows what its answers were built from. An answer that arrives
  /// without its sources is the thing this app is trying not to be.
  Map<String, dynamic> toJson() => {
        'contentId': contentId,
        'source': source,
        'author': author,
        'tradition': tradition,
        'sourceUrl': sourceUrl,
      };

  static Citation fromJson(Map<String, dynamic> json) => Citation(
        contentId: json['contentId'] as int? ?? 0,
        source: json['source'] as String? ?? 'Unknown source',
        author: json['author'] as String?,
        tradition: json['tradition'] as String?,
        sourceUrl: json['sourceUrl'] as String?,
      );

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

  /// Written by a language model, rather than composed by the app.
  final bool generated;

  ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.citations,
    this.generated = false,
  });

  factory ChatMessage.fromStored(StoredMessage stored) => ChatMessage(
        text: stored.text,
        isUser: stored.isUser,
        timestamp: stored.createdAt,
        generated: stored.generated,
        citations: stored.citations.isEmpty
            ? null
            : stored.citations.map(Citation.fromJson).toList(),
      );
}