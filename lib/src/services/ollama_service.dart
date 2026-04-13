import 'dart:convert';
import 'package:http/http.dart' as http;

class OllamaService {
  final String baseUrl;
  final String defaultModel;
  
  OllamaService({
    this.baseUrl = 'http://localhost:11434',
    this.defaultModel = 'llama3.2',
  });
  
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
    final request = http.Request(
      'POST',
      Uri.parse('$baseUrl/api/generate'),
    );
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode({
      'model': model ?? defaultModel,
      'prompt': prompt,
      'system': system,
      'stream': true,
      'options': {
        'temperature': temperature,
      },
    });
    
    final client = http.Client();
    try {
      final response = await client.send(request);
      
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        for (final line in chunk.split('\n')) {
          if (line.trim().isEmpty) continue;
          try {
            final data = jsonDecode(line);
            if (data['response'] != null) {
              yield data['response'] as String;
            }
            if (data['done'] == true) break;
          } catch (_) {
            // Skip malformed JSON lines
          }
        }
      }
    } finally {
      client.close();
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
      contextBuilder.writeln(passage.content);
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