/// The picture path, end to end, exactly as the application runs it.
///
/// `Scanner.scanImageBytes` is what both screens call once a file has been
/// chosen: the platform codec, then the scanner over RGBA. The picker itself is
/// the only part left out, because it needs a person.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxscan_example/scanner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async => Scanner.init());

  for (final name in ['qr_clean.png', 'qr_photo.jpg', 'qr_portrait.png']) {
    test('reads $name', () async {
      final bytes = await File('test/$name').readAsBytes();
      final outcome = await Scanner.scanImageBytes(bytes);
      // ignore: avoid_print
      print('$name -> ${outcome.width}x${outcome.height}, '
          '${outcome.results.length} decoded, '
          '${outcome.candidates.length} candidates');
      expect(outcome.results, isNotEmpty);
    });
  }
}
