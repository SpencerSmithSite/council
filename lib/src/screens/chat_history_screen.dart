import 'package:flutter/material.dart';

import '../services/chat_history_service.dart';
import '../util/relative_date.dart';

/// Past conversations, most recently active first.
///
/// Picking one does not open a second copy of it here — it is handed back to
/// the caller, which puts it in the Ask tab. Two live views of the same thread,
/// each appending to it, is a way to lose messages.
class ChatHistoryScreen extends StatefulWidget {
  const ChatHistoryScreen({super.key});

  @override
  State<ChatHistoryScreen> createState() => _ChatHistoryScreenState();
}

class _ChatHistoryScreenState extends State<ChatHistoryScreen> {
  final _history = ChatHistoryService();
  List<Conversation>? _conversations;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final conversations = await _history.conversations();
    if (mounted) setState(() => _conversations = conversations);
  }

  @override
  Widget build(BuildContext context) {
    final conversations = _conversations;

    return Scaffold(
      appBar: AppBar(title: const Text('Chat history')),
      body: conversations == null
          ? const Center(child: CircularProgressIndicator())
          : conversations.isEmpty
              ? _empty(context)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: conversations.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) =>
                        _tile(context, conversations[index]),
                  ),
                ),
    );
  }

  Widget _tile(BuildContext context, Conversation conversation) {
    final theme = Theme.of(context);
    final preview =
        (conversation.preview ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

    return Dismissible(
      key: ValueKey('conversation-${conversation.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: theme.colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Icon(Icons.delete_outline,
            color: theme.colorScheme.onErrorContainer),
      ),
      confirmDismiss: (_) async {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Delete this conversation?'),
            content: const Text('The whole thread will be removed.'),
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
      },
      onDismissed: (_) async {
        await _history.deleteConversation(conversation.id);
        await _load();
      },
      child: ListTile(
        isThreeLine: preview.isNotEmpty,
        leading: Icon(
          // A thread that began from a selected passage is a different kind of
          // thing from a question asked cold, and the list says so.
          conversation.passage != null
              ? Icons.format_quote
              : Icons.chat_bubble_outline,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(
          conversation.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (preview.isNotEmpty)
              Text(preview, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(
              '${formatWhen(conversation.updatedAt)} · '
              '${conversation.messageCount} '
              '${conversation.messageCount == 1 ? 'message' : 'messages'}',
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
        onTap: () => Navigator.pop(context, conversation.id),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 56, color: scheme.outline),
            const SizedBox(height: 16),
            Text('No conversations yet',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Questions you ask — from the Ask tab, or about a passage while '
              'reading — are kept here so you can pick them back up.',
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
