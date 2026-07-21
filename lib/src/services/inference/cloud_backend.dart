import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'inference_backend.dart';

/// A cloud provider the user holds their own API key for.
///
/// There is no official Anthropic (or Google) SDK for Dart, so these speak the
/// REST APIs directly. The wire formats differ enough that each provider gets
/// its own request builder and stream decoder.
enum CloudProvider {
  anthropic(
    id: 'anthropic',
    label: 'Claude',
    endpoint: 'https://api.anthropic.com/v1/messages',
    defaultModel: 'claude-opus-4-8',
    models: ['claude-opus-4-8', 'claude-sonnet-5', 'claude-haiku-4-5'],
    keyUrl: 'https://console.anthropic.com/settings/keys',
  ),
  openai(
    id: 'openai',
    label: 'ChatGPT',
    endpoint: 'https://api.openai.com/v1/chat/completions',
    defaultModel: 'gpt-4o',
    models: ['gpt-4o', 'gpt-4o-mini'],
    keyUrl: 'https://platform.openai.com/api-keys',
  ),
  gemini(
    id: 'gemini',
    label: 'Gemini',
    endpoint: 'https://generativelanguage.googleapis.com/v1beta/models',
    defaultModel: 'gemini-2.0-flash',
    models: ['gemini-2.0-flash', 'gemini-1.5-pro'],
    keyUrl: 'https://aistudio.google.com/app/apikey',
  ),
  xai(
    id: 'xai',
    label: 'Grok',
    endpoint: 'https://api.x.ai/v1/chat/completions',
    defaultModel: 'grok-2-latest',
    models: ['grok-2-latest'],
    keyUrl: 'https://console.x.ai',
  );

  const CloudProvider({
    required this.id,
    required this.label,
    required this.endpoint,
    required this.defaultModel,
    required this.models,
    required this.keyUrl,
  });

  final String id;
  final String label;
  final String endpoint;
  final String defaultModel;
  final List<String> models;

  /// Where the user goes to create a key — shown in Settings.
  final String keyUrl;

  static CloudProvider fromId(String id) =>
      CloudProvider.values.firstWhere((p) => p.id == id,
          orElse: () => CloudProvider.anthropic);
}

class CloudBackend implements InferenceBackend {
  final CloudProvider provider;
  final String model;
  final String apiKey;

  CloudBackend({
    required this.provider,
    required this.model,
    required this.apiKey,
  });

  @override
  String get id => provider.id;

  @override
  String get displayName => provider.label;

  @override
  String get description =>
      'Uses your own ${provider.label} API key. Questions and the retrieved '
      'passages are sent to ${Uri.parse(provider.endpoint).host}.';

  /// Explicitly not private: this is the one backend that leaves the device.
  @override
  bool get isPrivate => false;

  /// Cloud models have very large context windows, so retrieval can be far
  /// more generous here than with an on-device model.
  @override
  int get contextBudgetChars => 60000;

  @override
  Future<BackendStatus> checkStatus() async {
    if (apiKey.trim().isEmpty) {
      return BackendStatus.unavailable(
        'No ${provider.label} API key saved. Add one in Settings.',
      );
    }
    return BackendStatus.available('Using your ${provider.label} key');
  }

  @override
  Future<List<String>> availableModels() async => provider.models;

  Uri _uri() {
    if (provider == CloudProvider.gemini) {
      // Gemini puts the model in the path and the key in the query string.
      return Uri.parse(
        '${provider.endpoint}/$model:streamGenerateContent?alt=sse&key=$apiKey',
      );
    }
    return Uri.parse(provider.endpoint);
  }

  Map<String, String> _headers() {
    final headers = {'Content-Type': 'application/json'};
    switch (provider) {
      case CloudProvider.anthropic:
        headers['x-api-key'] = apiKey;
        headers['anthropic-version'] = '2023-06-01';
      case CloudProvider.openai:
      case CloudProvider.xai:
        headers['Authorization'] = 'Bearer $apiKey';
      case CloudProvider.gemini:
        break; // key travels in the query string
    }
    return headers;
  }

  String _body(String prompt, String? system) {
    switch (provider) {
      case CloudProvider.anthropic:
        return jsonEncode({
          'model': model,
          // Required by the Messages API, unlike the OpenAI-shaped providers.
          'max_tokens': 4096,
          if (system != null) 'system': system,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
          'stream': true,
          // Deliberately no temperature/top_p/top_k: current Claude models
          // reject sampling parameters with a 400.
        });

      case CloudProvider.openai:
      case CloudProvider.xai:
        return jsonEncode({
          'model': model,
          'messages': [
            if (system != null) {'role': 'system', 'content': system},
            {'role': 'user', 'content': prompt},
          ],
          'stream': true,
        });

      case CloudProvider.gemini:
        return jsonEncode({
          if (system != null)
            'systemInstruction': {
              'parts': [
                {'text': system}
              ]
            },
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': prompt}
              ]
            }
          ],
        });
    }
  }

  /// Pull the incremental text out of one decoded SSE payload.
  String? _extractDelta(Map<String, dynamic> data) {
    switch (provider) {
      case CloudProvider.anthropic:
        if (data['type'] != 'content_block_delta') return null;
        final delta = data['delta'];
        if (delta is Map && delta['type'] == 'text_delta') {
          return delta['text'] as String?;
        }
        return null;

      case CloudProvider.openai:
      case CloudProvider.xai:
        final choices = data['choices'];
        if (choices is! List || choices.isEmpty) return null;
        final delta = choices.first['delta'];
        return delta is Map ? delta['content'] as String? : null;

      case CloudProvider.gemini:
        final candidates = data['candidates'];
        if (candidates is! List || candidates.isEmpty) return null;
        final parts = candidates.first['content']?['parts'];
        if (parts is! List || parts.isEmpty) return null;
        return parts.first['text'] as String?;
    }
  }

  @override
  Stream<String> generate({required String prompt, String? system}) async* {
    final request = http.Request('POST', _uri())
      ..headers.addAll(_headers())
      ..body = _body(prompt, system);

    final client = http.Client();
    try {
      final response = await client.send(request);

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw InferenceException(_describeError(response.statusCode, body));
      }

      // All four providers stream Server-Sent Events; chunk boundaries do not
      // respect line boundaries, so buffer until a newline is actually seen.
      var buffer = '';
      await for (final chunk
          in response.stream.transform(utf8.decoder)) {
        buffer += chunk;
        while (true) {
          final newline = buffer.indexOf('\n');
          if (newline < 0) break;
          final line = buffer.substring(0, newline).trim();
          buffer = buffer.substring(newline + 1);

          if (!line.startsWith('data:')) continue;
          final payload = line.substring(5).trim();
          if (payload.isEmpty || payload == '[DONE]') continue;

          try {
            final text = _extractDelta(jsonDecode(payload));
            if (text != null && text.isNotEmpty) yield text;
          } on FormatException {
            // Keep-alives and comments are not JSON; ignore them.
          }
        }
      }
    } finally {
      client.close();
    }
  }

  String _describeError(int status, String body) {
    // Surface the provider's own message when it sends one — it is almost
    // always more useful than a status code.
    try {
      final decoded = jsonDecode(body);
      final message = decoded is Map
          ? (decoded['error']?['message'] ?? decoded['message'])
          : null;
      if (message is String && message.isNotEmpty) {
        return '${provider.label}: $message';
      }
    } on FormatException {
      // fall through
    }

    return switch (status) {
      401 || 403 => '${provider.label} rejected the API key. Check it in Settings.',
      404 => '${provider.label} does not recognise the model "$model".',
      429 => '${provider.label} rate limit reached. Try again shortly.',
      _ => '${provider.label} request failed (HTTP $status).',
    };
  }

  @override
  void dispose() {}
}
