/// The picture path on a real device.
///
/// Same code both screens run once a file has been chosen — the platform
/// codec, then the scanner over RGBA — but on the phone, against the native
/// library built for it. The picker is left out so that this needs nobody to
/// tap anything, which is what makes it usable for chasing a fault on a device
/// that is not in front of you.
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wxscan_example/scanner.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the weights load', (tester) async {
    final nn = await Scanner.init();
    debugPrint('[probe] models loaded: $nn');
    expect(nn, isTrue, reason: 'the CNN weights are bundled and should load');
  });

  for (final name in ['qr_clean.png', 'qr_photo.jpg', 'qr_sample.png']) {
    testWidgets('reads $name', (tester) async {
      await Scanner.init();
      final bytes =
          (await rootBundle.load('assets/test/$name')).buffer.asUint8List();
      final outcome = await Scanner.scanImageBytes(bytes);
      debugPrint('[probe] $name -> ${outcome.width}x${outcome.height}, '
          '${outcome.results.length} decoded, '
          '${outcome.candidates.length} candidates');
      expect(outcome.results, isNotEmpty);
    });

    testWidgets('reads $name from a path, natively', (tester) async {
      await Scanner.init();
      // What the application now does with a picked file: the bytes never
      // become a Dart pixel buffer. Written out first because an asset lives
      // in the bundle rather than on the filesystem.
      final data = await rootBundle.load('assets/test/$name');
      final file = File('${Directory.systemTemp.path}/probe_$name')
        ..writeAsBytesSync(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      addTearDown(file.deleteSync);
      final outcome = await Scanner.scanPicked(file.path);
      debugPrint('[probe] path $name -> ${outcome.width}x${outcome.height}, '
          '${outcome.results.length} decoded');
      expect(outcome.results, isNotEmpty);
    });
  }
}
