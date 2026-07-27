import 'package:flutter/material.dart';

import '../services/annotation_service.dart';
import '../theme/highlight_colours.dart';
import '../util/relative_date.dart';
import 'content_detail_screen.dart';
import 'note_editor_screen.dart';

/// Everything the reader has written or marked, newest first.
///
/// Two lists rather than one. A note is a thought and is opened to be read
/// again; a highlight is a bookmark of emphasis and is opened to get back to
/// the page. Mixing them would bury the handful of notes under the marks, since
/// highlighting is by far the cheaper gesture.
class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen>
    with SingleTickerProviderStateMixin {
  final _annotations = AnnotationService();
  late final TabController _tabs = TabController(length: 2, vsync: this);

  List<Note>? _notes;
  List<Highlight>? _highlights;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final notes = await _annotations.allNotes();
    final highlights = await _annotations.allHighlights();
    if (!mounted) return;
    setState(() {
      _notes = notes;
      _highlights = highlights;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notes'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: 'Notes'), Tab(text: 'Highlights')],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _NotesList(notes: _notes, onChanged: _load),
          _HighlightsList(highlights: _highlights, onChanged: _load),
        ],
      ),
    );
  }
}

class _NotesList extends StatelessWidget {
  final List<Note>? notes;
  final Future<void> Function() onChanged;

  const _NotesList({required this.notes, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    if (notes == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (notes!.isEmpty) {
      return const _Empty(
        icon: Icons.sticky_note_2_outlined,
        title: 'No notes yet',
        detail: 'While reading, tap a verse or paragraph and choose the note '
            'button to write about it.',
      );
    }

    return RefreshIndicator(
      onRefresh: onChanged,
      child: ListView.separated(
        itemCount: notes!.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final note = notes![index];
          return Dismissible(
            key: ValueKey('note-${note.id}'),
            direction: DismissDirection.endToStart,
            background: const _DeleteBackground(),
            confirmDismiss: (_) => _confirmDelete(context),
            onDismissed: (_) async {
              await AnnotationService().deleteNote(note.id);
              await onChanged();
            },
            child: ListTile(
              isThreeLine: true,
              title: Text(
                note.body.isEmpty ? '(no text)' : note.body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w500),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if ((note.quote ?? '').isNotEmpty)
                    Text(
                      '“${note.quote!}”',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontStyle: FontStyle.italic,
                          ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    _caption(note.reference, note.sourceTitle, note.updatedAt),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => NoteEditorScreen(note: note),
                  ),
                );
                await onChanged();
              },
            ),
          );
        },
      ),
    );
  }
}

class _HighlightsList extends StatelessWidget {
  final List<Highlight>? highlights;
  final Future<void> Function() onChanged;

  const _HighlightsList({required this.highlights, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    if (highlights == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (highlights!.isEmpty) {
      return const _Empty(
        icon: Icons.palette_outlined,
        title: 'Nothing highlighted yet',
        detail: 'Tap a verse or paragraph while reading, then choose a colour.',
      );
    }

    final brightness = Theme.of(context).brightness;

    return RefreshIndicator(
      onRefresh: onChanged,
      child: ListView.separated(
        itemCount: highlights!.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final highlight = highlights![index];
          return Dismissible(
            key: ValueKey('highlight-${highlight.id}'),
            direction: DismissDirection.endToStart,
            background: const _DeleteBackground(),
            confirmDismiss: (_) => _confirmDelete(context),
            onDismissed: (_) async {
              await AnnotationService().deleteHighlight(highlight.id);
              await onChanged();
            },
            child: ListTile(
              leading: Container(
                width: 12,
                height: 36,
                decoration: BoxDecoration(
                  color: HighlightColour.fromId(highlight.colour)
                      .resolve(brightness),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              title: Text(
                highlight.quote,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _caption(highlight.reference, highlight.sourceTitle,
                      highlight.createdAt),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      ContentDetailScreen(contentId: highlight.contentUnitId),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

Future<bool> _confirmDelete(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Delete?'),
      content: const Text('This cannot be undone.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

String _caption(String? reference, String? source, DateTime when) {
  return [
    if ((reference ?? '').isNotEmpty) reference!,
    if ((source ?? '').isNotEmpty) source!,
    formatWhen(when),
  ].join(' · ');
}

class _DeleteBackground extends StatelessWidget {
  const _DeleteBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.errorContainer,
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Icon(Icons.delete_outline,
          color: Theme.of(context).colorScheme.onErrorContainer),
    );
  }
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;

  const _Empty({
    required this.icon,
    required this.title,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: scheme.outline),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
