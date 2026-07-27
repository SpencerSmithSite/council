import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/annotation_service.dart';
import 'content_detail_screen.dart';

/// Writing about a passage.
///
/// The quotation sits above the field and cannot be edited — it is the
/// corpus's words, and a note whose quotation has been rewritten is worse than
/// no note. Everything below it belongs to the reader.
///
/// There is no Save button. The note is written when the screen closes, which
/// is what every notes app on either platform does; a note the reader typed and
/// lost to a back gesture is the failure worth designing against.
class NoteEditorScreen extends StatefulWidget {
  final Note note;

  /// True when the note was just created from a selection, so the keyboard
  /// comes up ready rather than making the reader tap again.
  final bool autofocus;

  const NoteEditorScreen({
    super.key,
    required this.note,
    this.autofocus = false,
  });

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  final _annotations = AnnotationService();
  late final TextEditingController _body =
      TextEditingController(text: widget.note.body);

  bool _deleted = false;

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  /// Persist, or — for a note that was created by the act of opening this
  /// screen and never written in — remove it again.
  ///
  /// Without this, tapping "note" and changing your mind would leave a bare
  /// quotation in the Notes list forever.
  Future<void> _commit() async {
    if (_deleted) return;
    final body = _body.text.trim();
    if (body.isEmpty && widget.note.body.isEmpty) {
      await _annotations.deleteNote(widget.note.id);
      return;
    }
    if (body != widget.note.body) {
      await _annotations.updateNoteBody(widget.note.id, body);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this note?'),
        content: const Text('What you wrote will be removed. '
            'The passage itself is untouched.'),
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
    if (confirmed != true) return;

    await _annotations.deleteNote(widget.note.id);
    _deleted = true;
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final note = widget.note;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _commit();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            note.reference?.isNotEmpty == true ? note.reference! : 'Note',
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (note.quote != null && note.quote!.isNotEmpty)
              IconButton(
                tooltip: 'Copy the passage',
                icon: const Icon(Icons.copy_rounded),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: note.quote!));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied')),
                  );
                },
              ),
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (note.quote != null && note.quote!.isNotEmpty)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                    border: Border(
                      left: BorderSide(color: scheme.primary, width: 3),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Capped, because a note about nine verses should still
                      // leave room to write. The whole passage is one tap away.
                      Text(
                        note.quote!,
                        maxLines: 8,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(height: 1.45),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              [
                                if (note.reference?.isNotEmpty == true)
                                  note.reference!,
                                if (note.sourceTitle?.isNotEmpty == true)
                                  note.sourceTitle!,
                              ].join(' · '),
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                          if (note.contentUnitId != null)
                            TextButton(
                              onPressed: () async {
                                await _commit();
                                if (!context.mounted) return;
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ContentDetailScreen(
                                      contentId: note.contentUnitId!,
                                    ),
                                  ),
                                );
                              },
                              child: const Text('Open passage'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: TextField(
                    controller: _body,
                    autofocus: widget.autofocus,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    keyboardType: TextInputType.multiline,
                    textCapitalization: TextCapitalization.sentences,
                    style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Your thoughts on this passage…',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
