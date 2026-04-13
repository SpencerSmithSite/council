import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../services/database_service.dart';
import '../services/ollama_service.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];
  bool _isLoading = false;
  bool _ollamaAvailable = false;
  String _selectedModel = 'llama3.2';
  List<String> _availableModels = [];
  
  late final DatabaseService _databaseService;
  late final OllamaService _ollamaService;
  
  @override
  void initState() {
    super.initState();
    _databaseService = DatabaseService();
    _ollamaService = OllamaService();
    _initializeServices();
  }
  
  Future<void> _initializeServices() async {
    try {
      await _databaseService.initialize();
      _ollamaAvailable = await _ollamaService.isAvailable();
      if (_ollamaAvailable) {
        _availableModels = await _ollamaService.getModels();
        if (_availableModels.isNotEmpty) {
          _selectedModel = _availableModels.first;
        }
      }
      setState(() {});
    } catch (e) {
      // Services failed to initialize
      setState(() {
        _ollamaAvailable = false;
      });
    }
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
    
    // Add user message
    setState(() {
      _messages.add(ChatMessage(
        text: text,
        isUser: true,
        timestamp: DateTime.now(),
      ));
      _isLoading = true;
    });
    
    _messageController.clear();
    _scrollToBottom();
    
    try {
      String response;
      List<String>? citations;
      
      if (_ollamaAvailable) {
        // Use combined FTS5 + tag search for better RAG retrieval
        final passages = await _databaseService.searchForRAG(text, limit: 5);
        
        if (passages.isNotEmpty) {
          // Build context from search results
          final contextPassages = passages.map((p) => ContextPassage(
            source: p['source_title'] ?? 'Unknown',
            content: p['content_plain'] ?? '',
            tradition: p['tradition'],
            date: p['date_composed'],
          )).toList();
          
          // Generate response with Ollama
          final result = await _ollamaService.generateWithContext(
            query: text,
            passages: contextPassages,
            model: _selectedModel,
          );
          
          response = result.response;
          citations = result.sources;
        } else {
          // No relevant passages found
          response = 'I couldn\'t find any relevant sources in the database for your question. Try rephrasing or asking about a different topic.';
          citations = [];
        }
      } else {
        // Ollama not available
        response = _getOfflineResponse(text);
        citations = [];
      }
      
      if (mounted) {
        setState(() {
          _messages.add(ChatMessage(
            text: response,
            isUser: false,
            timestamp: DateTime.now(),
            citations: citations,
          ));
          _isLoading = false;
        });
        
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _messages.add(ChatMessage(
            text: 'Error: ${e.toString()}',
            isUser: false,
            timestamp: DateTime.now(),
          ));
          _isLoading = false;
        });
        _scrollToBottom();
      }
    }
  }
  
  String _getOfflineResponse(String query) {
    return '''Ollama is not available. To enable AI responses:

1. Install Ollama: https://ollama.ai
2. Pull a model: `ollama pull llama3.2`
3. Restart the app

Your question: "$query"

The database has ${_messages.length} messages loaded, but AI responses require Ollama running locally.''';
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
          
          // Loading indicator
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Row(
                children: [
                  SizedBox(width: 12),
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Thinking...'),
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
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('About AI Chat'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    _ollamaAvailable ? Icons.check_circle : Icons.error_outline,
                    color: _ollamaAvailable ? Colors.green : Colors.orange,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _ollamaAvailable ? 'Ollama Connected' : 'Ollama Not Available',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              if (_ollamaAvailable && _availableModels.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Available models:'),
                ..._availableModels.map((m) => Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text('• $m'),
                )),
              ],
              const SizedBox(height: 16),
              const Text('Setup:'),
              const SizedBox(height: 8),
              const Text('1. Install Ollama from ollama.ai'),
              const Text('2. Pull a model: ollama pull llama3.2'),
              const Text('3. Ollama runs automatically on port 11434'),
              const SizedBox(height: 16),
              const Text('Privacy:'),
              const SizedBox(height: 8),
              const Text('• All processing happens locally'),
              const Text('• No data sent to cloud'),
              const Text('• Conversation history stored on device only'),
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

class _SuggestionChip extends StatelessWidget {
  final String text;
  final Function(String)? onTap;
  
  const _SuggestionChip(this.text, {super.key, this.onTap});
  
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
            
            if (message.citations != null && message.citations!.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 8),
              Text(
                'Sources:',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: message.citations!
                    .map((c) => Chip(
                          label: Text(c, style: const TextStyle(fontSize: 12)),
                          visualDensity: VisualDensity.compact,
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

class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final List<String>? citations;
  
  ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.citations,
  });
}