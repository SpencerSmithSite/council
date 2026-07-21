import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The corpus ships gzipped and is decompressed on first launch. If the asset
/// were missing, mis-declared in pubspec, or not actually gzip, the app would
/// fail at startup on a fresh install only — which is exactly the failure that
/// is easiest to miss in development, since an already-installed database
/// keeps working.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled corpus asset decompresses to a valid SQLite database', () async {
    final data = await rootBundle.load('assets/theology.db.gz');
    final compressed = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );

    expect(compressed.length, greaterThan(1024), reason: 'asset looks empty');
    // gzip magic number
    expect(compressed[0], 0x1f);
    expect(compressed[1], 0x8b);

    final bytes = gzip.decode(compressed);

    // Every SQLite file begins with this header string.
    final header = String.fromCharCodes(bytes.take(15));
    expect(header, 'SQLite format 3');
    expect(bytes.length, greaterThan(compressed.length));
  });
}
