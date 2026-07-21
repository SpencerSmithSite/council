import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

import 'wordpiece_tokenizer.dart';

/// Encodes a search query into the same vector space as the corpus.
///
/// The corpus vectors were precomputed at build time with all-MiniLM-L6-v2,
/// quantized. This runs *that same model file* on the query. Document and query
/// vectors must come from one model — a different or unquantized model would
/// not error, it would just quietly rank worse — which is why the model ships
/// as an asset rather than being fetched, and why the tokenizer is a
/// reimplementation tested against the Python one rather than an approximation.
class QueryEncoder {
  static const int dims = 384;
  static const String _modelAsset = 'assets/model/model_quantized.onnx';

  final OrtSession _session;
  final WordPieceTokenizer _tokenizer;

  QueryEncoder._(this._session, this._tokenizer);

  static bool _runtimeInitialised = false;

  /// Load the model and tokenizer. Costs ~20 MB of memory and a moment of
  /// startup, so callers should do it lazily and tolerate failure: an app
  /// whose semantic search is unavailable should still search lexically.
  static Future<QueryEncoder> load() async {
    if (!_runtimeInitialised) {
      OrtEnv.instance.init();
      _runtimeInitialised = true;
    }

    final tokenizer = await WordPieceTokenizer.load();
    final modelData = await rootBundle.load(_modelAsset);
    final session = OrtSession.fromBuffer(
      modelData.buffer.asUint8List(
        modelData.offsetInBytes,
        modelData.lengthInBytes,
      ),
      OrtSessionOptions(),
    );

    return QueryEncoder._(session, tokenizer);
  }

  /// Encode [query] to an L2-normalized vector.
  ///
  /// Mirrors the build-time pipeline exactly: tokenize, run the model, mean-pool
  /// over real tokens only, then normalize. Pooling over padding instead of
  /// real tokens is the classic way to get a vector that looks plausible and
  /// retrieves badly.
  Future<Float32List> encode(String query) async {
    final ids = _tokenizer.encode(query);
    final length = ids.length;

    final inputIds = OrtValueTensor.createTensorWithDataList(
      Int64List.fromList(ids.map((i) => i.toInt()).toList()),
      [1, length],
    );
    final attentionMask = OrtValueTensor.createTensorWithDataList(
      Int64List.fromList(List.filled(length, 1)),
      [1, length],
    );
    final tokenTypeIds = OrtValueTensor.createTensorWithDataList(
      Int64List.fromList(List.filled(length, 0)),
      [1, length],
    );

    try {
      final outputs = _session.run(
        OrtRunOptions(),
        {
          'input_ids': inputIds,
          'attention_mask': attentionMask,
          'token_type_ids': tokenTypeIds,
        },
      );

      // [batch, sequence, dims] — batch of one.
      final hidden = outputs.first?.value as List;
      final sequence = (hidden.first as List).cast<List>();

      final pooled = Float32List(dims);
      for (final token in sequence) {
        final values = token.cast<double>();
        for (var d = 0; d < dims; d++) {
          pooled[d] += values[d];
        }
      }

      var norm = 0.0;
      for (var d = 0; d < dims; d++) {
        pooled[d] /= sequence.length;
        norm += pooled[d] * pooled[d];
      }
      norm = math.sqrt(norm);
      if (norm > 0) {
        for (var d = 0; d < dims; d++) {
          pooled[d] /= norm;
        }
      }

      for (final output in outputs) {
        output?.release();
      }
      return pooled;
    } finally {
      inputIds.release();
      attentionMask.release();
      tokenTypeIds.release();
    }
  }

  void dispose() => _session.release();
}
