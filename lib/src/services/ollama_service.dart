import 'dart:convert';
import 'dart:io' show SocketException;
import 'package:http/http.dart' as http;

class OllamaService {
  final String baseUrl;
  final String defaultModel;

  OllamaService({
    this.baseUrl = 'http://localhost:11434',
    this.defaultModel = 'llama3.2',
  });

  /// Load the model into memory ahead of the first question.
  ///
  /// The first `/api/generate` after selecting Ollama can take tens of seconds
  /// while the server loads a multi-gigabyte model, and during that silent gap
  /// the connection is liable to be reset (notably by the Android emulator's
  /// NAT). Sending an empty-prompt request with a `keep_alive` makes *this*
  /// throwaway call pay the cold start, so the real question streams from a warm
  /// model. Best-effort: any failure here is swallowed because the real request
  /// will still run (and surface its own error if something is genuinely wrong).
  Future<void> preload({String? model}) async {
    try {
      await http
          .post(
            Uri.parse('$baseUrl/api/generate'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': model ?? defaultModel,
              'prompt': '',
              'stream': false,
              // Keep the model resident long enough to cover a session's first
              // few questions without reloading.
              'keep_alive': '30m',
            }),
          )
          .timeout(const Duration(minutes: 5));
    } catch (_) {
      // Warming is best-effort; the real request handles real failures.
    }
  }

  /// Whether an error looks like a connection dropped mid-handshake — the
  /// signature of a cold model load resetting the socket before any token is
  /// sent, rather than a genuine "server is down" failure.
  static bool _looksLikeColdStart(Object e) {
    if (e is SocketException) return true;
    final s = e.toString().toLowerCase();
    return s.contains('connection abort') ||
        s.contains('connection reset') ||
        s.contains('connection closed') ||
        s.contains('software caused') ||
        s.contains('connection terminated');
  }

  /// Check if Ollama is running
  Future<bool> isAvailable() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/api/tags'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
  
  /// Get list of available models
  Future<List<String>> getModels() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/api/tags'));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final models = data['models'] as List;
        return models.map((m) => m['name'] as String).toList();
      }
      
      return [];
    } catch (e) {
      return [];
    }
  }
  
  /// Generate a response (non-streaming)
  Future<String> generate({
    required String prompt,
    String? system,
    String? model,
    double temperature = 0.7,
    int? numPredict,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/generate'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'model': model ?? defaultModel,
        'prompt': prompt,
        'system': system,
        'stream': false,
        'options': {
          'temperature': temperature,
          if (numPredict != null) 'num_predict': numPredict,
        },
      }),
    );
    
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['response'] as String;
    } else {
      throw OllamaException('Failed to generate: ${response.statusCode}');
    }
  }
  
  /// Generate a response with streaming (for real-time display)
  Stream<String> generateStream({
    required String prompt,
    String? system,
    String? model,
    double temperature = 0.7,
  }) async* {
    final body = jsonEncode({
      'model': model ?? defaultModel,
      'prompt': prompt,
      'system': system,
      'stream': true,
      'keep_alive': '30m',
      'options': {
        'temperature': temperature,
      },
    });

    // A cold model load can reset the connection before the first token — the
    // failure a user hits when they ask before the model is resident. Retry a
    // few times, but only while nothing has been streamed yet, so a mid-answer
    // drop is never replayed as a duplicated response. Once the model is loaded
    // the next attempt streams immediately.
    const maxAttempts = 3;
    for (var attempt = 1;; attempt++) {
      final client = http.Client();
      var streamedAnything = false;
      try {
        final request = http.Request('POST', Uri.parse('$baseUrl/api/generate'))
          ..headers['Content-Type'] = 'application/json'
          ..body = body;
        final response = await client.send(request);
        if (response.statusCode != 200) {
          throw OllamaException('Failed to generate: ${response.statusCode}');
        }

        await for (final chunk in response.stream.transform(utf8.decoder)) {
          for (final line in chunk.split('\n')) {
            if (line.trim().isEmpty) continue;
            try {
              final data = jsonDecode(line);
              final piece = data['response'];
              if (piece is String && piece.isNotEmpty) {
                streamedAnything = true;
                yield piece;
              }
              if (data['done'] == true) return;
            } catch (_) {
              // Skip malformed JSON lines.
            }
          }
        }
        return; // Stream ended without an explicit done flag.
      } catch (e) {
        final retriable = attempt < maxAttempts &&
            !streamedAnything &&
            _looksLikeColdStart(e);
        if (!retriable) rethrow;
        // Back off a little, then try again against a now-warmer model.
        await Future.delayed(Duration(seconds: 2 * attempt));
      } finally {
        client.close();
      }
    }
  }
  
  /// Generate with context (RAG-style)
  Future<GenerateResult> generateWithContext({
    required String query,
    required List<ContextPassage> passages,
    String? model,
    double temperature = 0.7,
  }) async {
    // Build system prompt
    final systemPrompt = buildSystemPrompt();
    
    // Build context from passages
    final contextBuilder = StringBuffer();
    contextBuilder.writeln('Relevant sources:');
    contextBuilder.writeln();
    
    for (int i = 0; i < passages.length; i++) {
      final passage = passages[i];
      contextBuilder.writeln('[${i + 1}] ${passage.source}');
      contextBuilder.writeln(passage.contextContent);
      contextBuilder.writeln();
    }
    
    // Build full prompt
    final fullPrompt = '''
$contextBuilder

User question: $query

Please answer the question using the provided sources. Include citations like [1], [2], etc. when referencing specific sources.
''';
    
    final response = await generate(
      prompt: fullPrompt,
      system: systemPrompt,
      model: model,
      temperature: temperature,
    );
    
    return GenerateResult(
      response: response,
      sources: passages.map((p) => p.source).toList(),
    );
  }
  
  String buildSystemPrompt() {
    return '''You are a theological research assistant. Your role is to provide accurate, well-sourced answers about Christian theology, drawing from historical sources including Church Fathers, councils, and confessions of faith.

Guidelines:
- Always cite your sources using [1], [2], etc.
- Present multiple traditions fairly when relevant
- Distinguish between historical teaching and personal interpretation
- Be precise about dates and attributions
- If uncertain or the sources don't address the question, say so
- Keep responses focused and relevant to the question''';
  }
  
  /// Check model availability and pull if needed
  Future<bool> ensureModelAvailable(String modelName) async {
    final models = await getModels();
    
    if (models.any((m) => m.startsWith(modelName))) {
      return true;
    }
    
    // Try to pull the model
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/pull'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': modelName}),
      );
      
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
}

class ContextPassage {
  /// Per-passage character budget for RAG context.
  ///
  /// Passage lengths are wildly uneven — most are a few hundred characters but
  /// the longest single unit is ~83 KB, which would blow a local model's
  /// context window on its own.
  static const int maxContextChars = 1500;

  final String source;
  final String content;
  final String? tradition;
  final String? date;

  ContextPassage({
    required this.source,
    required this.content,
    this.tradition,
    this.date,
  });

  /// [content] trimmed to [maxContextChars], cut at a word boundary so the
  /// model doesn't receive a truncated word.
  String get contextContent {
    if (content.length <= maxContextChars) return content;

    final clipped = content.substring(0, maxContextChars);
    final lastSpace = clipped.lastIndexOf(RegExp(r'\s'));
    final cut = lastSpace > maxContextChars ~/ 2 ? lastSpace : maxContextChars;

    return '${content.substring(0, cut).trimRight()}… [passage truncated]';
  }
}

class GenerateResult {
  final String response;
  final List<String> sources;
  
  GenerateResult({
    required this.response,
    required this.sources,
  });
}

class OllamaException implements Exception {
  final String message;
  
  OllamaException(this.message);
  
  @override
  String toString() => 'OllamaException: $message';
}