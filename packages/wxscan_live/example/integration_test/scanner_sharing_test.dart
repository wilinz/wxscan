/// Lending the camera a scanner, on a real device.
///
/// The Dart tests for this stand the platform in with a fake, so they say
/// nothing about the half of the mechanism that lives in Kotlin and Swift —
/// which is exactly where its two worst bugs were. This runs against the real
/// plugin, the real camera, and the real native library.
///
/// The instrument is [WxScanner.liveCount]. It reads the scanner table inside
/// the native library, and a scanner the *plugin* builds for itself goes into
/// that same table, so from here the count says how many exist in the process
/// however they were made. That is what makes "the camera did not build a
/// second one" an assertion rather than a hope.
///
/// Camera permission has to be granted from outside, since nothing here can
/// tap a system dialog — and `flutter test` reinstalls the application, which
/// resets a runtime permission granted before it ran. So the grant has to land
/// while the test is starting:
///
/// ```sh
/// flutter test integration_test/scanner_sharing_test.dart -d <device> &
/// until adb shell pm grant com.wilinz.wxscan android.permission.CAMERA; do sleep 0.3; done
/// ```
///
/// [openCamera] below waits for that, so the two only have to meet within a
/// few seconds of each other.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show PlatformException, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wxscan/wxscan.dart';
import 'package:wxscan_live/wxscan_live.dart';

Future<Uint8List> _asset(String path) async {
  final data = await rootBundle.load(path);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// Opens the camera, waiting for permission to arrive if it has not yet.
///
/// The plugin answers `NO_PERMISSION` by asking for it and telling the caller
/// to try again, which is exactly what this does — long enough for a grant
/// from outside the application to land.
Future<void> openCamera(
  WxScanController c, {
  Uint8List? detectModel,
  Uint8List? srModel,
}) async {
  for (var attempt = 0; ; attempt++) {
    try {
      await c.initialize(detectModel: detectModel, srModel: srModel);
      expect(c.value.isInitialized, isTrue);
      return;
    } on PlatformException catch (e) {
      if (e.code != 'NO_PERMISSION' || attempt >= 40) rethrow;
      if (attempt == 0) {
        debugPrint('[probe] waiting for camera permission');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
}

/// Waits for the camera to actually deliver a decoded frame.
///
/// One frame proves the whole path: the camera is bound, the analyser is
/// running, and the handle it holds names a live scanner. A camera that kept a
/// released handle would go on previewing and emit nothing, which is the
/// silent failure these tests exist to catch, so the timeout is the assertion.
Future<void> expectFramesFlowing(WxScanController c, {String? reason}) async {
  await expectLater(
    c.scans.first.timeout(const Duration(seconds: 5)),
    completes,
    reason: reason,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Uint8List detect;
  late Uint8List sr;

  setUpAll(() async {
    detect = await _asset('assets/models/detect.tflite');
    sr = await _asset('assets/models/sr.tflite');
  });

  testWidgets('without a lent scanner the camera builds one of its own', (
    tester,
  ) async {
    final before = WxScanner.liveCount;

    final c = WxScanController();
    await openCamera(c, detectModel: detect, srModel: sr);

    expect(
      WxScanner.liveCount,
      before + 1,
      reason: 'the plugin built a scanner, and it is in the same table',
    );
    expect(c.value.modelsLoaded, isTrue, reason: 'from the weights just sent');
    await expectFramesFlowing(c);

    c.dispose();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      WxScanner.liveCount,
      before,
      reason: 'and gave it back when the camera closed',
    );
  });

  testWidgets('a lent scanner is borrowed, not copied', (tester) async {
    final before = WxScanner.liveCount;
    final scanner = await WxScanner.create(detectModel: detect, srModel: sr);
    expect(WxScanner.liveCount, before + 1);

    final c = WxScanController(scanner: scanner);
    await openCamera(c, detectModel: detect, srModel: sr);

    // The whole point: one scanner, one copy of the weights.
    expect(
      WxScanner.liveCount,
      before + 1,
      reason: 'the camera took a reference rather than building a second',
    );
    expect(
      c.value.modelsLoaded,
      isTrue,
      reason: 'asked of the lent scanner, not inferred from weights',
    );
    await expectFramesFlowing(c, reason: 'decoding through the lent scanner');

    // Closing the camera must not free a scanner the application still holds.
    c.dispose();
    await tester.pump(const Duration(milliseconds: 500));
    expect(WxScanner.liveCount, before + 1);
    final gray = Uint8List(64 * 64)..fillRange(0, 64 * 64, 255);
    await expectLater(
      scanner.scanGray(gray, 64, 64),
      completes,
      reason: 'the lent scanner outlived the camera that borrowed it',
    );

    await scanner.dispose();
    expect(WxScanner.liveCount, before);
  });

  testWidgets('the application may let go before the camera does', (
    tester,
  ) async {
    final before = WxScanner.liveCount;
    final scanner = await WxScanner.create(detectModel: detect, srModel: sr);
    final c = WxScanController(scanner: scanner);
    await openCamera(c);

    // The ordering that would be a use-after-free without the counting: the
    // side that created the scanner lets go while the camera is still
    // decoding with it.
    await scanner.dispose();
    expect(
      WxScanner.liveCount,
      before + 1,
      reason: 'the camera still holds a reference',
    );
    await expectFramesFlowing(c, reason: 'and goes on decoding with it');

    c.dispose();
    await tester.pump(const Duration(milliseconds: 500));
    expect(WxScanner.liveCount, before, reason: 'the last holder freed it');
  });

  testWidgets('a takeover swaps the scanner, and gives the old one back', (
    tester,
  ) async {
    // The regression this file was written for, as the ownership rule leaves
    // it. A second controller initializing while the first camera runs used to
    // release the scanner the camera was decoding with and adopt the
    // newcomer's *while the first controller went on believing it owned the
    // camera* — and when the newcomer was disposed, the first was left
    // decoding against a handle of zero, previewing and never decoding again,
    // silently.
    //
    // The swap itself is now the intended thing: the camera goes to whoever
    // asked last, so the scanner does too. What this checks is that the swap
    // is a whole one — the reference to A's scanner is given back rather than
    // dropped or freed, and B's is taken exactly once.
    final before = WxScanner.liveCount;

    final scannerA = await WxScanner.create(detectModel: detect, srModel: sr);
    final a = WxScanController(scanner: scannerA);
    await openCamera(a);
    await expectFramesFlowing(a, reason: 'A is decoding to begin with');

    final scannerB = await WxScanner.create(detectModel: detect, srModel: sr);
    final b = WxScanController(scanner: scannerB);
    await openCamera(b);
    // The release of A's scanner is queued behind whatever frame was in
    // flight, so the count settles a moment after the call returns.
    await tester.pump(const Duration(seconds: 1));

    expect(
      WxScanner.liveCount,
      before + 2,
      reason:
          'two scanners, both held by Dart; the plugin built neither '
          'and freed neither',
    );
    await expectFramesFlowing(b, reason: 'B decodes through its own scanner');

    b.dispose();
    await tester.pump(const Duration(seconds: 1));
    expect(
      WxScanner.liveCount,
      before + 2,
      reason: 'closing the camera gives back the plugin\'s reference only',
    );

    a.dispose();
    await tester.pump(const Duration(milliseconds: 500));
    await scannerA.dispose();
    await scannerB.dispose();
    expect(WxScanner.liveCount, before);
  });

  testWidgets('a second controller takes the camera, and the first is told', (
    tester,
  ) async {
    // Found by this file, on a device, and the reason the ownership rule
    // exists. The device has one camera session and the plugin is a singleton
    // over it. A second controller's `initialize` used to take the "already
    // running" branch and *succeed*, reporting the first camera's texture and
    // state as its own — so the second controller believed it owned a camera.
    // Its `dispose` then tore that camera down, and the first controller was
    // left with a preview that had stopped and a scan stream that had gone
    // quiet, with nothing said to it.
    //
    // The rule now is that the camera goes to whoever asked last and the one
    // that had it is told. Which leaves the mirror image to check, and it is
    // the one that can only be checked here: the controller that *lost* the
    // camera must not close it when it is disposed. That is enforced by the
    // session number the platform mints and Dart sends back with the close,
    // and no fake platform can see it work.
    final before = WxScanner.liveCount;

    final scannerA = await WxScanner.create(detectModel: detect, srModel: sr);
    final a = WxScanController(scanner: scannerA);
    await openCamera(a);
    await expectFramesFlowing(a, reason: 'A is decoding to begin with');

    final b = WxScanController();
    await openCamera(b, detectModel: detect, srModel: sr);
    await tester.pump(const Duration(seconds: 1));

    expect(
      a.value.isInitialized,
      isFalse,
      reason: 'A does not have a camera any more',
    );
    expect(
      a.value.error,
      isA<WxCameraLost>(),
      reason: 'and it was told, rather than going quiet',
    );
    expect(
      WxScanner.liveCount,
      before + 2,
      reason:
          "A's scanner, still held by Dart, and the one B had the "
          'plugin build',
    );
    await expectFramesFlowing(b, reason: 'B has the camera now');

    // The assertion this test exists for.
    a.dispose();
    await tester.pump(const Duration(seconds: 1));
    await expectFramesFlowing(
      b,
      reason:
          'disposing the controller that lost the camera must not '
          'close the camera that took it',
    );

    b.dispose();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      WxScanner.liveCount,
      before + 1,
      reason: "B's camera gave back the scanner it built",
    );
    await scannerA.dispose();
    expect(WxScanner.liveCount, before);
  });
}
