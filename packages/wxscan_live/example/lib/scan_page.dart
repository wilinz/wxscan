import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wxscan_live/wxscan_live.dart';

import 'pick_overlay.dart';
import 'pick_page.dart';
import 'result_page.dart';
import 'scanner.dart';

/// The scanning screen: camera preview, a viewfinder, and the corners of
/// whatever was decoded highlighted.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> with WidgetsBindingObserver {
  /// The camera. Null until it is opened, and everything about its state —
  /// the preview size, the torch, the zoom — lives in `_controller.value`
  /// rather than being mirrored here.
  WxScanController? _controller;
  StreamSubscription<ScanOutcome>? _sub;
  String? _error;
  bool _hasTorch = false;
  bool _nnEnabled = false;

  /// Results from the most recent frame, used to draw the highlights.
  ScanOutcome? _lastFrame;

  /// The frame frozen when one frame held several codes; non-null means we
  /// are waiting for the user to pick one.
  ScanOutcome? _pickFrame;

  /// The result page is up, so further frames are ignored.
  bool _navigating = false;

  /// The device's maximum zoom, for zooming in automatically.
  double _maxZoom = 1;

  /// The zoom the device last confirmed, which the controller keeps.
  double get _zoom => _controller?.value.zoom ?? 1;

  /// Redraws when the controller's value changes: a rotation, a torch the
  /// device confirmed, a zoom it clamped.
  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  /// How many frames in a row saw a code without decoding it. Zooming waits
  /// for enough of them, so the picture does not jitter.
  int _undecodableStreak = 0;

  /// How many frames in a row saw nothing at all; enough of them and the
  /// zoom is wound back.
  int _emptyStreak = 0;

  /// When frames stopped holding anything at all, for [_blindFocus]. Null
  /// while the last frame had something in it.
  DateTime? _nothingSince;

  /// When "one code decoded, but more than one seen" started. Non-null means
  /// we are waiting for the second one; see [_kMultiCodeGrace].
  DateTime? _multiWaitSince;

  /// The capture resolution step. 720p by default; a dense code that will
  /// not come out can be given more, at the cost of a slower frame.
  WxResolution _resolution = WxResolution.p720;

  DateTime _lastZoomAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// The ratio the pinch started at, which the gesture works from.
  double _gestureZoomBase = 1;

  /// When the zoom was last set by hand. Automatic zooming keeps out for a
  /// while afterwards, or the two fight each other.
  DateTime _manualZoomAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// The picture frozen while picking, which is the very frame that was
  /// scanned, so the markers line up with it for free.
  Uint8List? _frozenFrame;

  /// When picking was left. Automatic zooming holds off just afterwards, or
  /// the user sees a zoom right after several codes flashed by.
  DateTime _pickExitAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Where the last tap to focus landed, in the shell's coordinates, and the
  /// timer that takes the reticle away again. Null when nothing is showing.
  Offset? _focusPoint;
  Timer? _focusTimer;

  /// When focus was last pointed by hand. Automatic focusing keeps out for a
  /// while afterwards, the way automatic zooming does.
  DateTime _manualFocusAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// When focus was last pointed automatically, and where to.
  DateTime _lastAutoFocusAt = DateTime.fromMillisecondsSinceEpoch(0);
  Offset? _lastAutoFocusPoint;

  /// The ratio the zoom is walking towards, and the timer walking it there.
  /// See [_stepZoom].
  double _zoomTarget = 1;
  Timer? _zoomDriver;
  var _zoomBusy = false;

  /// How much of full speed the walk is up to, 0 to 1, and when it last
  /// stepped. Together they make the walk neither start nor stop with a jerk;
  /// see [_stepZoom].
  double _zoomRate = 0;
  DateTime _zoomSteppedAt = DateTime.fromMillisecondsSinceEpoch(0);


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  Future<void> _boot() async {
    try {
      _nnEnabled = await Scanner.init();
      if (kDebugMode) {
        // Verify both paths on a device: direct FFI and the native camera path.
        unawaited(Scanner.selfTest());
      }

      // permission_handler has no macOS implementation, so on the desktop
      // the plugin asks AVFoundation itself inside initialize, which brings
      // up the system prompt the first time.
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        final status = await Permission.camera.request();
        if (!status.isGranted) {
          // The prompt can be answered after the page is gone.
          if (mounted) {
            setState(() => _error = 'Camera permission is needed to scan');
          }
          return;
        }
      }

      // One scanner for the whole application: the camera decodes with the
      // same one that reads pictures from the library, so there is a single
      // copy of the weights and a single set of thresholds. Scanner.instance
      // is null only if init() failed, and then the controller builds its own
      // from the model bytes.
      final controller = WxScanController(
        scanner: Scanner.instance,
        resolution: _resolution,
      );
      await controller.initialize(
        // Only reached when init() failed and there is no scanner to lend, so
        // the camera builds its own. Bytes in a browser, paths everywhere
        // else; exactly one pair is set.
        detectModel: Scanner.detectModel,
        srModel: Scanner.srModel,
        detectModelPath: Scanner.detectModelPath,
        srModelPath: Scanner.srModelPath,
      );
      if (kDebugMode) {
        unawaited(Scanner.selfTestCameraPath());
      }
      final hasTorch = await controller.hasTorch();
      final zoom = await controller.zoomRange();
      _maxZoom = zoom.max;
      if (!mounted) {
        controller.dispose();
        return;
      }
      // Wired up only once the page is certain to keep this controller.
      // Subscribing before the check above left the frame subscription alive
      // on a page that had already been popped: `dispose` had run, with
      // nothing in `_sub` to cancel.
      //
      // The preview size lives in the controller and follows rotations by
      // itself; the listener only asks the screen to redraw when it changes.
      controller.addListener(_onControllerChanged);
      _sub = controller.scans.listen(_onFrame);
      setState(() {
        _controller = controller;
        _hasTorch = hasTorch;
        _error = controller.value.nativeReady
            ? null
            : 'The native scanner failed to load';
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _error = '${e.code}: ${e.message}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  void _onFrame(ScanOutcome frame) {
    // Do not refresh while picking, or the codes jump about with each new
    // frame and cannot be tapped.
    if (!mounted || _navigating) return;
    setState(() => _lastFrame = frame);

    // Picking is frozen: the picture is held, scanning has stopped, and new
    // frames are ignored.
    if (_pickFrame != null) return;

    if (frame.results.isEmpty) {
      _multiWaitSince = null;
      _autoZoom(frame);
      _autoFocus(frame);
      _blindFocus(frame);
      return;
    }
    // Decoded, so the zoom has done its job and is wound back.
    _resetZoom();
    _nothingSince = null;

    // Several codes in one frame: freeze the picture and let the user pick.
    // Freezing is required -- with the preview still running the picture
    // changes with every movement of the hand, while the markers belong to
    // this one frame, and the two can never line up.
    if (frame.results.length > 1) {
      _multiWaitSince = null;
      HapticFeedback.mediumImpact();
      _enterPick(frame);
      return;
    }

    // One decoded, but detection saw more than one box: there are probably
    // two codes in view and the other has not come out in this frame yet
    // (frames are a good deal slower with several codes). Going to the result
    // page now would mean the user never gets the chance to pick, so wait a
    // few frames for the second one.
    if (frame.candidates.length > 1) {
      final now = DateTime.now();
      _multiWaitSince ??= now;
      // If it does not arrive, take the single code: the other may be too
      // small or too blurred to decode at all.
      if (now.difference(_multiWaitSince!) < _kMultiCodeGrace) return;
    }
    _multiWaitSince = null;
    _openResults(frame.results);
  }

  /// Enters picking: stops scanning and freezes the current picture, which
  /// is the very frame that was scanned.
  Future<void> _enterPick(ScanOutcome frame) async {
    setState(() => _pickFrame = frame);
    await _controller!.setScanning(false);
    final jpeg = await _controller!.grabFrame();
    if (!mounted || _pickFrame == null) return;
    setState(() => _frozenFrame = jpeg);
  }

  void _exitPick() {
    _multiWaitSince = null;
    setState(() {
      _pickFrame = null;
      _frozenFrame = null;
      // The previous frame's results go too: otherwise, until a new frame
      // arrives, the markers keep being drawn from the frame before picking
      // began, which looks like a box that will not go away.
      _lastFrame = null;
    });
    _pickExitAt = DateTime.now();
    _controller!.setScanning(true);
  }

  void _openResults(List<ScanResult> results) {
    _navigating = true;
    _controller!.setScanning(false);
    HapticFeedback.mediumImpact();
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => ResultPage(results: results),
        ))
        .then((_) {
          _navigating = false;
          _multiWaitSince = null;
          if (mounted) {
            setState(() {
              _pickFrame = null;
              _frozenFrame = null;
              _lastFrame = null;
            });
          }
          _resetZoom();
          _controller!.setScanning(true);
        });
  }

  /// Zooms in automatically: a code that is seen but will not decode is
  /// usually too small, so move closer for the user.
  ///
  /// The evidence comes from the candidate boxes of Rust's detection stage --
  /// boxes without results means seen but not read. An empty result set alone
  /// is not enough, since it is also empty when there is no code in view at
  /// all, and zooming then is pure nuisance.
  void _autoZoom(ScanOutcome frame) {
    final nowTs = DateTime.now();
    // Do not grab the wheel just after the user zoomed by hand, or just
    // after picking ended.
    if (nowTs.difference(_manualZoomAt) < _kManualZoomHold) return;
    if (nowTs.difference(_pickExitAt) < _kPickExitZoomHold) return;
    if (!frame.hasUndecodable) {
      _undecodableStreak = 0;
      // Seeing nothing for long enough winds the zoom back, or it would
      // stay zoomed in for good.
      if (frame.candidates.isEmpty && ++_emptyStreak > 45) _resetZoom();
      return;
    }
    _emptyStreak = 0;
    // Only act after several frames agree; one frame can misdetect.
    if (++_undecodableStreak < 3) return;

    final box = _largestCandidateBox(frame);
    if (box == null) return;
    final frac = math.max(box.w, box.h);
    if (frac <= 0 || frac >= _kZoomTargetFraction) return;

    // This much is wanted, but not more than keeps the code inside the
    // frame, so take the smaller.
    final rel = math.min(_kZoomTargetFraction / frac, _safeZoomHeadroom(box));
    final want = (_zoom * rel)
        .clamp(1.0, math.min(_maxZoom, _kMaxAutoZoom))
        .toDouble();
    // Nothing worth walking towards.
    if (want <= _zoom * 1.02) return;

    // Only the target is set here. Every frame revises it, and as the picture
    // closes in the code grows, `frac` with it and the target comes down to
    // meet the ratio — so this settles itself rather than overshooting.
    _zoomTarget = want;
    _startZoomDriver();
  }

  /// Walks the zoom towards [_zoomTarget].
  ///
  /// Setting the ratio straight to the target moves the picture in one jump,
  /// which is what a scanner looks like when it is guessing, and it throws the
  /// code the user was holding steady somewhere else. But an even walk in
  /// fixed steps is no better: ten visible steps a second is a slideshow, and
  /// it starts and stops dead.
  ///
  /// So: a step every [_kZoomStepEvery], each one closing a fixed *fraction*
  /// of what is left. That decelerates into the target on its own, the way a
  /// hand does. Two things shape it further — the arithmetic is done on the
  /// logarithm of the ratio, since zoom is multiplicative and equal steps are
  /// only equal to the eye there; and the speed is ramped in over
  /// [_kZoomRampIn] rather than being at full rate from the first step, which
  /// is what made the start read as a lurch.
  void _startZoomDriver() {
    if (_zoomDriver != null) return;
    _zoomRate = 0;
    _zoomSteppedAt = DateTime.now();
    _zoomDriver = Timer.periodic(_kZoomStepEvery, (_) => _stepZoom());
  }

  void _stopZoomDriver() {
    _zoomDriver?.cancel();
    _zoomDriver = null;
    _zoomRate = 0;
  }

  void _stepZoom() {
    // One call at a time: the ratio that took effect comes back from the
    // device, and stepping from a stale one walks past the target.
    if (_zoomBusy) return;
    final from = _zoom;
    if ((_zoomTarget / from - 1).abs() < 0.005) {
      _stopZoomDriver();
      return;
    }

    // Measured rather than assumed: a timer under load fires late, and a step
    // sized for 33ms taken after 90 would crawl.
    final now = DateTime.now();
    final dt = now.difference(_zoomSteppedAt).inMicroseconds / 1e6;
    _zoomSteppedAt = now;
    if (dt <= 0) return;

    _zoomRate =
        math.min(1.0, _zoomRate + dt / (_kZoomRampIn.inMilliseconds / 1000));
    // The fraction of the remaining distance a step of this length closes.
    // Written as an exponential so the walk looks the same however often the
    // timer actually fires.
    final k = 1 - math.exp(-dt / (_kZoomSettle.inMilliseconds / 1000));

    final logFrom = math.log(from);
    final next =
        math.exp(logFrom + (math.log(_zoomTarget) - logFrom) * k * _zoomRate);

    _zoomBusy = true;
    _controller!.setZoom(next).then((actual) {
      _zoomBusy = false;
      if (!mounted) return;
      // The controller already holds it; this only redraws.
      setState(() {});
      // The device would go no further. Asking again every step would be a
      // platform call thirty times a second for nothing.
      if ((actual - from).abs() < 0.0005 && _zoomRate >= 1) {
        _zoomTarget = actual;
        _stopZoomDriver();
      }
    });
  }

  /// Focuses on a code that is seen but will not decode.
  ///
  /// A small code is usually a soft one as well: it sits somewhere inside the
  /// frame, and continuous auto-focus, which weighs the middle of the picture,
  /// holds the wall behind it sharp instead. Pointing focus at the box is
  /// often the whole difference between a code that comes out and one that
  /// does not, and it costs nothing where the code was sharp already.
  ///
  /// Kept apart from [_autoZoom]: the two answer the same trouble by different
  /// means, and a code too far off centre to zoom towards -- CameraX zooms
  /// about the centre and nowhere else -- can still be focused on.
  void _autoFocus(ScanOutcome frame) {
    if (!frame.hasUndecodable) return;

    // One frame is enough, where the zoom waits for three. The two are not
    // the same bet: a zoom that fires on a misdetection throws the picture
    // about and loses whatever the user was aiming at, while a focus that
    // fires on one is at worst a lens moving to a place with nothing there,
    // which the next frame corrects and which costs nothing meanwhile. Waiting
    // three frames only delays the reading it was going to make possible.
    final now = DateTime.now();
    if (now.difference(_manualFocusAt) < _kManualFocusHold) return;
    if (now.difference(_lastAutoFocusAt) < _kAutoFocusInterval) return;

    final box = _largestCandidateBox(frame);
    if (box == null) return;
    // Only the small ones. A code filling much of the picture is already
    // where continuous focus is looking, and pointing at it again would only
    // set the lens hunting.
    final frac = math.max(box.w, box.h);
    if (frac <= 0 || frac >= _kAutoFocusMaxFraction) return;

    // A code sitting still is focused on once, not every second and a half:
    // each request starts the lens moving again, and a picture that keeps
    // softening and sharpening is worse than one that settled.
    final point = Offset(box.cx, box.cy);
    final last = _lastAutoFocusPoint;
    if (last != null &&
        (point - last).distance < _kAutoFocusMoved &&
        now.difference(_lastAutoFocusAt) < _kAutoFocusRepeat) {
      return;
    }

    final turns = _controller?.value.previewSize?.quarterTurns ?? 0;
    final (x, y) = _previewFraction(box.cx, box.cy, turns);
    if (x < 0 || x > 1 || y < 0 || y > 1) return;

    _lastAutoFocusAt = now;
    _lastAutoFocusPoint = point;
    unawaited(_controller!.focusAt(x, y));
  }

  /// Focuses when there is nothing to focus on.
  ///
  /// [_autoFocus] needs a candidate box, and a picture too soft to detect
  /// anything in has none. That is a state that holds itself shut: no box, so
  /// nothing asks for focus, so the box never comes. A scanner opens in it
  /// whenever the lens is left where the last session put it, and continuous
  /// auto-focus does not rescue it — continuous reacts to what changes, and a
  /// phone held steady over a code changes nothing.
  ///
  /// So stop waiting for the detector. Once a second of frames has held
  /// neither a result nor a candidate, the picture is worth nothing as it
  /// stands: a scan at the centre is the only thing that can change that, and
  /// there is no reading in progress for it to interrupt.
  void _blindFocus(ScanOutcome frame) {
    final now = DateTime.now();
    if (frame.candidates.isNotEmpty) {
      _nothingSince = null;
      return;
    }
    // Timed rather than counted in frames, which is what everything else here
    // does: a frame is a whole CNN pass, so its rate falls with the resolution
    // and with the device, and a count of them would mean half a second on one
    // phone and three on another.
    final since = _nothingSince ??= now;
    if (now.difference(since) < _kBlindFocusAfter) return;

    if (now.difference(_manualFocusAt) < _kManualFocusHold) return;
    // Shares the clock with [_autoFocus] so the two cannot both drive the
    // lens: whichever has something to say, the other holds off.
    if (now.difference(_lastAutoFocusAt) < _kBlindFocusInterval) return;

    _lastAutoFocusAt = now;
    // Nothing was aimed at, so there is no point to compare the next one
    // against.
    _lastAutoFocusPoint = null;
    unawaited(_controller!.focusAt(0.5, 0.5));
  }

  void _resetZoom() {
    _undecodableStreak = 0;
    _emptyStreak = 0;
    if (_zoomTarget == 1 && _zoom == 1) return;
    // Back out the way it came in, rather than dropping to 1x in one frame.
    _zoomTarget = 1;
    _startZoomDriver();
  }

  /// The largest candidate box, with coordinates normalised to [0,1] in each
  /// dimension.
  ({double cx, double cy, double w, double h})? _largestCandidateBox(
      ScanOutcome f) {
    if (f.width == 0 || f.height == 0) return null;
    ({double cx, double cy, double w, double h})? best;
    var bestArea = 0.0;
    for (final c in f.candidates) {
      if (c.length < 4) continue;
      var minX = double.infinity, maxX = -double.infinity;
      var minY = double.infinity, maxY = -double.infinity;
      for (final p in c) {
        minX = math.min(minX, p.dx);
        maxX = math.max(maxX, p.dx);
        minY = math.min(minY, p.dy);
        maxY = math.max(maxY, p.dy);
      }
      final w = (maxX - minX) / f.width;
      final h = (maxY - minY) / f.height;
      if (w * h > bestArea) {
        bestArea = w * h;
        best = (
          cx: (minX + maxX) / 2 / f.width,
          cy: (minY + maxY) / 2 / f.height,
          w: w,
          h: h,
        );
      }
    }
    return best;
  }

  /// How much further it can zoom without pushing the code out of frame.
  ///
  /// CameraX can only zoom about the *centre* of the picture; there is no API
  /// for a zoom centre. So the further the code is from the centre, the less
  /// room there is. At a zoom of z the visible region is a window of side 1/z
  /// centred on 0.5, and keeping the code entirely inside it requires
  /// |c-0.5| + half the side <= 1/(2z). For a code far off centre this comes
  /// out near 1, meaning it should not zoom: doing so would only lose the code
  /// further, and waiting for the user to move over is better.
  double _safeZoomHeadroom(({double cx, double cy, double w, double h}) box) {
    double axis(double center, double size) {
      final margin = (center - 0.5).abs() + size / 2;
      return margin <= 0 ? _kMaxAutoZoom : 1 / (2 * margin);
    }

    return math.min(axis(box.cx, box.w), axis(box.cy, box.h));
  }

  /// Pinch to zoom. One-finger scale events are ignored, or a tap to pick
  /// would be taken for a zoom.
  void _onScaleStart(ScaleStartDetails d) {
    if (d.pointerCount >= 2) _gestureZoomBase = _zoom;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount < 2) return;
    final now = DateTime.now();
    // Gesture updates come thick, so they are throttled rather than
    // flooding setZoomRatio.
    if (now.difference(_lastZoomAt) < const Duration(milliseconds: 60)) return;

    final want = (_gestureZoomBase * d.scale).clamp(1.0, _maxZoom).toDouble();
    if ((want - _zoom).abs() < 0.02) return;
    _lastZoomAt = now;
    _manualZoomAt = now;
    // The hand is on it: the walk has nothing left to do, and would otherwise
    // pull against the fingers.
    _stopZoomDriver();
    _zoomTarget = want;
    _controller!.setZoom(want).then((actual) {
      // The controller already holds it; this only redraws.
      if (mounted) setState(() {});
    });
  }

  /// Tap to focus.
  ///
  /// The preview is drawn by turning the picture through
  /// [WxPreviewSize.quarterTurns] and covering the box with what comes out, so
  /// a tap is brought back the other way: undo the cover fit against the
  /// turned size, then undo the turn, which leaves the fraction of the
  /// picture the plugin's own coordinates are in.
  ///
  /// A tap outside the picture — the bands a cover fit crops away are off the
  /// box, but a letterboxed one leaves them on it — is dropped rather than
  /// clamped, so the reticle never appears somewhere the camera is not
  /// looking.
  void _onFocusTap(Offset tap, Size box) {
    final size = _controller?.value.previewSize;
    if (size == null || _controller == null) return;

    final m = _coverFit(box, size.rotatedWidth, size.rotatedHeight);
    final rx = (tap.dx - m.dx) / (size.rotatedWidth * m.scale);
    final ry = (tap.dy - m.dy) / (size.rotatedHeight * m.scale);
    if (rx < 0 || rx > 1 || ry < 0 || ry > 1) return;

    final (x, y) = _previewFraction(rx, ry, size.quarterTurns);

    _manualFocusAt = DateTime.now();
    _focusTimer?.cancel();
    setState(() => _focusPoint = tap);
    _focusTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _focusPoint = null);
    });
    unawaited(_controller!.focusAt(x, y));
  }

  /// The layer that takes those taps, under the bars so their buttons are
  /// still buttons, and under the picker so picking a code still wins.
  Widget _buildFocusLayer() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: (d) => _onFocusTap(d.localPosition, box),
          child: const SizedBox.expand(),
        );
      },
    );
  }

  /// The layer for picking among several codes: tap a marker to open that
  /// code, tap anywhere else to go on scanning.
  Widget _buildPicker(ScanOutcome frame) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) {
            final hit =
                pickHitTest(d.localPosition, BoxFit.cover, size, frame);
            if (hit != null) {
              _openResults([hit]);
            } else {
              // Tapping elsewhere gives up on picking and scans on.
              _exitPick();
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The frozen frame covers the live preview. It is the same
              // frame at the same size, so the markers below line up exactly
              // under the same cover mapping.
              if (_frozenFrame != null)
                Image.memory(
                  _frozenFrame!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              // Filled explicitly: hit-testing uses the LayoutBuilder's size
              // and drawing uses the CustomPaint's, and the two have to agree
              // or taps and markers drift apart systematically.
              CustomPaint(
                size: Size.infinite,
                painter: PickPainter(frame: frame, fit: BoxFit.cover),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Cycles the capture resolution: 720p, 1080p, highest, and round again.
  ///
  /// The higher steps are for dense codes -- high version, many small modules,
  /// which simply will not come out without the pixels. The cost is a scan
  /// time that roughly follows the pixel count, which is why the default stays
  /// at 720p.
  Future<void> _cycleResolution() async {
    const order = WxResolution.values;
    final next = order[(order.indexOf(_resolution) + 1) % order.length];
    setState(() {
      _resolution = next;
      // A change of resolution changes the frame size, so the old results'
      // coordinates no longer mean anything.
      _lastFrame = null;
    });
    try {
      await _controller!.setResolution(next);
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = '${e.code}: ${e.message}');
    }
  }

  /// Decoding from the photo library, through the same Rust path the camera
  /// uses.
  Future<void> _pickFromGallery() async {
    final PickedPicture? picked;
    try {
      picked = await Scanner.pickAndScan();
    } on UnreadableImage {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('That file is not a picture this device can read'),
        ));
      }
      return;
    }
    // Aliased so the closure below can see it as non-null: a final assigned
    // inside a try is not promoted into one.
    if (picked == null || !mounted) return;
    final found = picked.outcome;
    if (found.results.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(found.candidates.isEmpty
            ? 'No QR code found in that picture'
            : 'A code was spotted but could not be read — it may be too small '
                'in the picture, or too blurred'),
      ));
      return;
    }
    _navigating = true;
    await _controller!.setScanning(false);
    if (!mounted) return;
    // Several codes in one picture, as on the home screen: the picture is
    // shown with a marker on each, and the reader says which.
    var results = found.results;
    if (results.length > 1) {
      final image = await picked.file.readAsBytes();
      if (!mounted) return;
      final chosen = await Navigator.of(context).push<ScanResult>(
        MaterialPageRoute<ScanResult>(
          builder: (_) => PickPage(image: image, outcome: found),
        ),
      );
      if (chosen == null) {
        _navigating = false;
        await _controller!.setScanning(true);
        return;
      }
      results = [chosen];
      if (!mounted) return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ResultPage(results: results),
      ),
    );
    _navigating = false;
    await _controller!.setScanning(true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Scanning stops in the background and resumes on return. The observer is
    // registered in initState, so this can arrive before the camera is up —
    // or never see one at all, if permission was refused.
    if (state == AppLifecycleState.resumed) {
      _controller?.setScanning(!_navigating);
    } else {
      _controller?.setScanning(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _controller?.removeListener(_onControllerChanged);
    _controller?.dispose();
    _controller = null;
    _focusTimer?.cancel();
    _zoomDriver?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Back while picking should leave picking and go on scanning, not leave
    // the page.
    return PopScope(
      canPop: _pickFrame == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _exitPick();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      // The zoom gesture wraps everything: as a layer inside the Stack it
      // would be shadowed by the hit-testing of the layers above. It does not
      // conflict with the tap to pick inside -- the gesture arena settles it,
      // one finger to the tap and two to the zoom.
      body: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        child: _Shell(
          child: Stack(
          fit: StackFit.expand,
          children: [
            if (_controller != null) _buildPreview(_controller!),
            // Decoration, and nothing that can be pressed. Without this a
            // CustomPaint takes every tap that reaches it: RenderCustomPaint
            // answers hitTestSelf with true unless its painter says otherwise,
            // so the viewfinder alone would swallow the taps meant for the
            // layer below it.
            const IgnorePointer(child: _ScanLineOverlay()),
            if (_lastFrame != null && _controller != null && _pickFrame == null)
              IgnorePointer(
                child: CustomPaint(
                  painter: _CodeMarkerPainter(frame: _lastFrame!),
                ),
              ),
            if (_controller != null) _buildFocusLayer(),
            if (_focusPoint != null) _FocusReticle(at: _focusPoint!),
            // Below the top and bottom bars, or its opaque hit-testing would
            // swallow taps meant for those buttons.
            if (_pickFrame != null) _buildPicker(_pickFrame!),
            _buildTopBar(),
            if (_error != null) _buildError(_error!),
            _buildBottomBar(),
          ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildPreview(WxScanController controller) {
    // The preview is always upright with respect to the device's natural
    // orientation, so however far the screen turned is made up here, and the
    // box outside is sized to the dimensions after that. The two have to
    // agree, or BoxFit.cover stretches by the wrong ratio.
    final size = controller.value.previewSize;
    if (size == null) return const SizedBox.shrink();
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: size.rotatedWidth.toDouble(),
          height: size.rotatedHeight.toDouble(),
          child: RotatedBox(
            quarterTurns: size.quarterTurns,
            child: SizedBox(
              width: size.width.toDouble(),
              height: size.height.toDouble(),
              child: WxScanPreview(controller: controller),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    // Aligned rather than dropped straight into the stack: an expanded stack
    // hands its children tight constraints, and a row told it is as tall as
    // the screen centres its contents down the middle of it.
    return Align(
      alignment: Alignment.topCenter,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: _pickFrame != null ? _buildPickBar() : _buildScanBar(),
        ),
      ),
    );
  }

  /// The top bar while picking: how to leave, and what to do.
  ///
  /// Both used to live inside the picker itself, where the back button landed
  /// on top of the title and the bottom bar went on telling the user to put a
  /// code in the frame while this one told them to tap a marker. One bar at a
  /// time says one thing.
  Widget _buildPickBar() {
    return Row(
      children: [
        IconButton(
          onPressed: _exitPick,
          tooltip: 'Back',
          style: IconButton.styleFrom(
            backgroundColor: Colors.black54,
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.arrow_back),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: _Hint('Tap a marker to open that code'),
        ),
      ],
    );
  }

  /// The height of the bar's first line, which is the back button's: an
  /// IconButton is a touch target before it is an icon, and everything beside
  /// it is centred against that rather than hung from the top.
  static const double _barLine = 48;

  Widget _buildScanBar() {
    return Row(
          // Top-aligned, so a second run of chips grows downwards instead of
          // pushing the button and the title off the line they share. Each
          // side centres itself within [_barLine] instead.
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: _barLine,
              child: Row(
                children: [
                  // Reached by a push from the home screen, so there has to be
                  // a way back that is not the system gesture: iOS and macOS
                  // do not have Android's, and nobody guesses at a tap on the
                  // picture.
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    tooltip: 'Back',
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black38,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Scan',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // A narrow phone cannot hold the title and both chips on one
            // line, so they wrap under each other rather than overflowing.
            // One run sits centred on the button's line; two make the box
            // taller and fill it.
            Expanded(
              // ConstrainedBox and a shrink-wrapping Align, not a Container
              // with an alignment: that one grows to whatever it is offered,
              // and what it is offered here is the height of the screen, which
              // put the chips down in the middle of the picture.
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: _barLine),
                child: Align(
                  alignment: Alignment.centerRight,
                  heightFactor: 1,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      // The resolution step, raised by a tap. Useful when a
                      // dense code will not come out.
                      _chip(
                        _resolution.label,
                        onTap: _controller == null ? null : _cycleResolution,
                        icon: Icons.hd_outlined,
                      ),
                      _chip(_nnEnabled
                          ? 'CNN detection on'
                          : 'Image processing only'),
                    ],
                  ),
                ),
              ),
            ),
          ],
    );
  }

  /// The small rounded label of the top bar. Tappable when given an onTap.
  Widget _chip(String text, {VoidCallback? onTap, IconData? icon}) {
    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: Colors.white70),
            const SizedBox(width: 4),
          ],
          Text(text,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
    if (onTap == null) return body;
    return GestureDetector(onTap: onTap, child: body);
  }

  Widget _buildError(String message) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.orange, size: 32),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                setState(() => _error = null);
                _boot();
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    // The top bar is doing the talking while picking, and the torch and the
    // gallery are no use with a frozen frame on screen.
    if (_pickFrame != null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Padding(
          // A phone in landscape has barely any room below the viewfinder,
          // and 40 of it would put the buttons off the bottom.
          padding: EdgeInsets.only(
              bottom: MediaQuery.sizeOf(context).height < 560 ? 12 : 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Hint(_zoom > 1
                  ? '${_zoom.toStringAsFixed(1)}x - pinch to zoom'
                  : 'Put the QR code in the frame to scan it'),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_hasTorch)
                    IconButton.filledTonal(
                      onPressed: () async {
                        await _controller!.setTorch(!_controller!.value.torchEnabled);
                        setState(() {});
                      },
                      icon: Icon(
                        _controller!.value.torchEnabled
                            ? Icons.flashlight_on
                            : Icons.flashlight_off,
                      ),
                    ),
                  const SizedBox(width: 24),
                  IconButton.filledTonal(
                    onPressed: _pickFromGallery,
                    icon: const Icon(Icons.photo_library_outlined),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Holds the scanner to a phone-shaped panel on a screen too big for it.
///
/// Everything in the scanner is laid out against one box: the preview covers
/// it, the viewfinder is drawn from its shortest side, and the markers and
/// their hit-testing map frame coordinates onto it. So the whole stack is
/// constrained together, never the preview alone — narrowing one layer and not
/// the others would put the markers somewhere the codes are not.
///
/// A phone is left alone. A desktop window is not a phone: filling it would
/// crop most of a 4:3 or 16:9 camera away and grow the viewfinder to the size
/// of a dinner plate.
class _Shell extends StatelessWidget {
  const _Shell({required this.child});

  final Widget child;

  /// Below either of these the screen is a phone's, or a window small enough
  /// to be treated as one. A phone in landscape is short, not large, which is
  /// why the height has a say.
  static const double _wideEnough = 720;
  static const double _tallEnough = 600;

  /// Width over height of the panel: a tall phone, which is the shape the
  /// scanner was drawn for.
  static const double _panelAspect = 0.52;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth, h = constraints.maxHeight;
        if (w < _wideEnough || h < _tallEnough) return child;

        final panelHeight = math.min(h - 48, 900.0);
        final panelWidth = math.min(w - 48, panelHeight * _panelAspect);
        return Center(
          child: SizedBox(
            width: panelWidth,
            height: panelHeight,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// A line of guidance over the camera picture.
///
/// It needs a ground of its own: bare text over a preview is legible against a
/// wall and vanishes against anything busy, which is most of what a camera
/// sees.
class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
      ),
    );
  }
}

/// The viewfinder: four corners and a sweeping line.
/// The four corners a camera draws where it was told to focus.
///
/// They come in wide and snap onto the point, then give one small pulse and
/// fade. It is the only sign the tap was taken: focus itself is invisible on a
/// code that was already sharp, and a tap that appears to do nothing reads as
/// a tap that was missed.
///
/// Corners rather than a closed square because the point of the gesture is to
/// say *there*, and an open shape leaves the thing being focused on visible
/// through it.
class _FocusReticle extends StatefulWidget {
  const _FocusReticle({required this.at});

  /// Where the tap landed, in the shell's coordinates.
  final Offset at;

  @override
  State<_FocusReticle> createState() => _FocusReticleState();
}

class _FocusReticleState extends State<_FocusReticle>
    with SingleTickerProviderStateMixin {
  /// The square the corners sit on once settled. Big enough to frame a code,
  /// small enough not to read as the viewfinder.
  static const double _size = 78;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..forward();

  @override
  void didUpdateWidget(_FocusReticle old) {
    super.didUpdateWidget(old);
    // A second tap reuses this widget, so the animation is started again
    // rather than sitting finished at the new place.
    if (widget.at != old.at) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Wide at first, onto the point by 260ms, then one pulse in and back.
  double _scaleAt(double t) {
    if (t < 0.24) {
      return 1.5 - 0.5 * Curves.easeOutCubic.transform(t / 0.24);
    }
    if (t < 0.46) {
      // The pulse: in a little and out again, which is what says the camera
      // acted rather than that the drawing merely arrived.
      final p = (t - 0.24) / 0.22;
      return 1.0 - 0.08 * math.sin(p * math.pi);
    }
    return 1.0;
  }

  double _opacityAt(double t) {
    if (t < 0.06) return t / 0.06;
    if (t < 0.72) return 1.0;
    return 1.0 - (t - 0.72) / 0.28;
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          final scale = _scaleAt(t);
          return Stack(
            children: [
              Positioned(
                left: widget.at.dx - _size / 2,
                top: widget.at.dy - _size / 2,
                child: Opacity(
                  opacity: _opacityAt(t).clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: scale,
                    child: CustomPaint(
                      size: const Size(_size, _size),
                      // The stroke is scaled the other way, so the lines keep
                      // one weight however wide the corners are standing.
                      painter: _FocusCornersPainter(strokeScale: 1 / scale),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Four L-shaped corners, drawn as one path so the joins are mitred.
class _FocusCornersPainter extends CustomPainter {
  const _FocusCornersPainter({required this.strokeScale});

  final double strokeScale;

  @override
  void paint(Canvas canvas, Size size) {
    // How far each arm runs along its edge.
    final arm = size.width * 0.28;
    final path = Path();
    for (final (cx, cy, sx, sy) in [
      (0.0, 0.0, 1.0, 1.0),
      (size.width, 0.0, -1.0, 1.0),
      (size.width, size.height, -1.0, -1.0),
      (0.0, size.height, 1.0, -1.0),
    ]) {
      path
        ..moveTo(cx + sx * arm, cy)
        ..lineTo(cx, cy)
        ..lineTo(cx, cy + sy * arm);
    }

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * strokeScale
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFF07C160),
    );
  }

  @override
  bool shouldRepaint(_FocusCornersPainter old) =>
      old.strokeScale != strokeScale;
}

/// The line that sweeps the picture, top to bottom, over and over.
///
/// There used to be a square viewfinder here, dimming everything outside
/// itself. The scanner reads the whole frame, so the square was telling the
/// user to aim at a region that was never the region being scanned, and the
/// dimming hid the rest of a picture that was perfectly live. What is left is
/// the one honest part: something is being looked at, and it is all of this.
class _ScanLineOverlay extends StatefulWidget {
  const _ScanLineOverlay();

  @override
  State<_ScanLineOverlay> createState() => _ScanLineOverlayState();
}

class _ScanLineOverlayState extends State<_ScanLineOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => CustomPaint(
        painter: _ScanLinePainter(progress: _controller.value),
        size: Size.infinite,
      ),
    );
  }
}

class _ScanLinePainter extends CustomPainter {
  _ScanLinePainter({required this.progress});

  final double progress;

  static const _green = Color(0xFF07C160);

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height * progress;

    // Faded in at the top and out at the bottom, so the return to the top
    // reads as the sweep starting again rather than as the line jumping.
    final fade = math.min(progress / 0.12, (1 - progress) / 0.12).clamp(0.0, 1.0);
    if (fade <= 0) return;

    // A trail above the line, longer than a square's would have been: at the
    // full height of a screen a bare rule reads as thin, and the trail is what
    // gives the sweep a direction.
    final trail = math.min(size.height * 0.14, 150.0);
    final top = math.max(y - trail, 0.0);
    if (y > top) {
      final band = Rect.fromLTRB(0, top, size.width, y);
      canvas.drawRect(
        band,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _green.withValues(alpha: 0),
              _green.withValues(alpha: 0.16 * fade),
            ],
          ).createShader(band),
      );
    }

    // The line itself, thinning towards the edges so it does not end in two
    // hard stops against the sides of the screen.
    final line = Rect.fromLTWH(0, y - 1, size.width, 2);
    canvas.drawRect(
      line,
      Paint()
        ..shader = LinearGradient(
          colors: [
            _green.withValues(alpha: 0),
            _green.withValues(alpha: fade),
            _green.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(line),
    );
  }

  @override
  bool shouldRepaint(_ScanLinePainter old) => old.progress != progress;
}

/// What automatic zooming aims for: the code filling this fraction of the
/// picture's short side.
const double _kZoomTargetFraction = 0.45;

/// How often the zoom takes a step towards its target. Thirty a second: past
/// the point where the steps can be told apart, and not so many that the
/// platform call becomes the cost.
const Duration _kZoomStepEvery = Duration(milliseconds: 33);

/// Roughly how long the zoom takes to close most of the way onto its target.
/// It is a time constant, not a duration: the last of the distance is walked
/// slowest, which is what makes the arrival soft.
const Duration _kZoomSettle = Duration(milliseconds: 420);

/// How long the walk takes to come up to full speed, so that it starts by
/// easing off the mark instead of lurching.
const Duration _kZoomRampIn = Duration(milliseconds: 260);

/// The ceiling for automatic zooming; beyond it the picture shakes too much
/// and the target is easily lost.
const double _kMaxAutoZoom = 4.0;

/// A code smaller than this fraction of the picture is what automatic focusing
/// is for. Bigger than that and continuous focus, which weighs the middle,
/// already has it.
const double _kAutoFocusMaxFraction = 0.45;

/// How long automatic focusing stands aside after a tap. Long enough for the
/// tap's own focus to settle and be seen, and no longer: pointing somewhere by
/// hand is a hint about where to look, not an instruction to stop looking.
const Duration _kManualFocusHold = Duration(seconds: 2);

/// The soonest it will point focus somewhere again.
const Duration _kAutoFocusInterval = Duration(milliseconds: 1500);

/// Moving this much across the picture counts as somewhere else, and is worth
/// focusing on before [_kAutoFocusRepeat] has passed.
const double _kAutoFocusMoved = 0.06;

/// The soonest it will focus on the same place twice.
const Duration _kAutoFocusRepeat = Duration(seconds: 4);

/// How long frames must hold nothing whatsoever before [_blindFocus] stops
/// waiting for the detector. Long enough not to fire while the camera is still
/// opening, short enough that someone who points the phone at a code and holds
/// still is not left holding it.
const Duration _kBlindFocusAfter = Duration(seconds: 1);

/// And how often it may try again. Slower than [_kAutoFocusInterval], because
/// it is aiming at nothing in particular and every scan softens the picture on
/// its way through.
const Duration _kBlindFocusInterval = Duration(seconds: 2);

/// How long automatic zooming stands aside after a manual one.
const Duration _kManualZoomHold = Duration(seconds: 5);

/// How long automatic zooming waits after picking ends.
const Duration _kPickExitZoomHold = Duration(seconds: 3);

/// With one code decoded but more than one seen by detection, this is the
/// longest it waits for the second to come out so that picking can begin.
/// Failing that it takes the single code, rather than leaving the user
/// staring.
const Duration _kMultiCodeGrace = Duration(milliseconds: 700);

/// A point of the scanned frame, as fractions of its width and height, in the
/// coordinates `focusAt` takes.
///
/// The frame arrives upright with respect to the screen. The texture holds the
/// picture upright with respect to the device, which is [quarterTurns]
/// clockwise from it, so the point is turned back the other way.
(double, double) _previewFraction(double fx, double fy, int quarterTurns) =>
    switch (quarterTurns) {
      1 => (fy, 1 - fx),
      2 => (1 - fx, 1 - fy),
      3 => (1 - fy, fx),
      _ => (fx, fy),
    };

/// The mapping from frame coordinates to screen coordinates.
///
/// The preview fills its box with BoxFit.cover, so this works the same way.
/// Drawing and hit-testing have to share one of these, or the markers drawn
/// and the places that can actually be tapped drift apart.
({double scale, double dx, double dy}) _coverFit(Size size, int fw, int fh) {
  final scale = math.max(size.width / fw, size.height / fh);
  return (
    scale: scale,
    dx: (size.width - fw * scale) / 2,
    dy: (size.height - fh * scale) / 2,
  );
}

/// Draws the four corners of each decoded code, mapping frame coordinates to
/// screen coordinates the way BoxFit.cover does.
class _CodeMarkerPainter extends CustomPainter {
  final ScanOutcome frame;

  _CodeMarkerPainter({required this.frame});

  @override
  void paint(Canvas canvas, Size size) {
    if (frame.results.isEmpty || frame.width == 0 || frame.height == 0) return;

    // The scanned frame's size can differ from the preview's, so the cover
    // mapping applies, shared with hit-testing.
    final m = _coverFit(size, frame.width, frame.height);
    final scale = m.scale;
    final dx = m.dx;
    final dy = m.dy;

    final paint = Paint()
      ..color = const Color(0xFF07C160)
      ..style = PaintingStyle.fill;

    for (final r in frame.results) {
      final path = Path();
      for (var i = 0; i < r.corners.length; i++) {
        final p = Offset(r.corners[i].dx * scale + dx, r.corners[i].dy * scale + dy);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF07C160).withValues(alpha: 0.25)
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF07C160)
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke,
      );
      // The centre point.
      final c = r.corners.centre;
      final cx = c.dx;
      final cy = c.dy;
      canvas.drawCircle(Offset(cx * scale + dx, cy * scale + dy), 8, paint);
    }
  }

  @override
  bool shouldRepaint(_CodeMarkerPainter old) => old.frame != frame;
}
