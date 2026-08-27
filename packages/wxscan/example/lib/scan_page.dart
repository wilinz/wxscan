import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wxscan/wxscan.dart';

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
  WxScanCameraInfo? _camera;
  StreamSubscription<ScanOutcome>? _sub;
  StreamSubscription<WxPreviewSize>? _sizeSub;
  WxPreviewSize? _previewSize;
  String? _error;
  bool _torch = false;
  bool _hasTorch = false;
  bool _nnEnabled = false;

  /// Results from the most recent frame, used to draw the highlights.
  ScanOutcome? _lastFrame;

  /// The frame frozen when one frame held several codes; non-null means we
  /// are waiting for the user to pick one.
  ScanOutcome? _pickFrame;

  /// The result page is up, so further frames are ignored.
  bool _navigating = false;

  /// The current zoom ratio and the device's maximum, for zooming in
  /// automatically.
  double _zoom = 1;
  double _maxZoom = 1;

  /// How many frames in a row saw a code without decoding it. Zooming waits
  /// for enough of them, so the picture does not jitter.
  int _undecodableStreak = 0;

  /// How many frames in a row saw nothing at all; enough of them and the
  /// zoom is wound back.
  int _emptyStreak = 0;

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
          setState(() => _error = 'Camera permission is needed to scan');
          return;
        }
      }

      // The plugin loads the models into its own scanner: camera frames stay
      // in the native layer, so they never reach the one Scanner holds.
      final info = await WxScan.initialize(
        resolution: _resolution,
        detectModel: Scanner.detectModel,
        srModel: Scanner.srModel,
      );
      _previewSize = WxPreviewSize(
          info.previewWidth, info.previewHeight, info.displayRotation);
      // A screen rotation changes the angle to make up, and can change the
      // size too.
      _sizeSub = WxScan.previewSizeStream.listen((s) {
        if (mounted) setState(() => _previewSize = s);
      });
      _sub = WxScan.scanStream.listen(_onFrame);
      if (kDebugMode) {
        unawaited(Scanner.selfTestCameraPath());
      }
      final hasTorch = await WxScan.hasTorch();
      final zoom = await WxScan.zoomRange();
      _maxZoom = zoom.max;
      if (!mounted) return;
      setState(() {
        _camera = info;
        _hasTorch = hasTorch;
        _error = info.nativeReady ? null : 'The native scanner failed to load';
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
      return;
    }
    // Decoded, so the zoom has done its job and is wound back.
    _resetZoom();

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
    await WxScan.setScanning(false);
    final jpeg = await WxScan.grabFrame();
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
    WxScan.setScanning(true);
  }

  void _openResults(List<ScanResult> results) {
    _navigating = true;
    WxScan.setScanning(false);
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
          WxScan.setScanning(true);
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

    final now = DateTime.now();
    if (now.difference(_lastZoomAt) < const Duration(milliseconds: 700)) return;

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
    // Too small a gain is not worth it; a jolt of the picture is worse than
    // no zoom.
    if (want <= _zoom * 1.15) return;

    _lastZoomAt = now;
    _undecodableStreak = 0;
    WxScan.setZoom(want).then((actual) {
      if (mounted) setState(() => _zoom = actual);
    });
  }

  void _resetZoom() {
    _undecodableStreak = 0;
    _emptyStreak = 0;
    if (_zoom == 1) return;
    _zoom = 1;
    WxScan.setZoom(1);
    if (mounted) setState(() {});
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
    WxScan.setZoom(want).then((actual) {
      if (mounted) setState(() => _zoom = actual);
    });
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
            final hit = _hitTest(d.localPosition, size, frame);
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
                painter: _PickPainter(frame: frame),
              ),
              // Leaving picking: the back button in the corner. Tapping
              // elsewhere and the system back gesture are not enough on their
              // own -- nobody guesses the first, and the second is Android's
              // alone and does not exist on iOS or macOS.
              Positioned(
                left: 4,
                top: 0,
                child: SafeArea(
                  child: IconButton(
                    onPressed: _exitPick,
                    tooltip: 'Back',
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black54,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.arrow_back),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 56),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Text(
                          'Tap a marker to open that code',
                          style:
                              TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The code nearest the tap; beyond the tolerance it counts as a miss.
  ScanResult? _hitTest(Offset tap, Size size, ScanOutcome frame) {
    ScanResult? best;
    var bestDist = double.infinity;
    for (final r in frame.results) {
      if (r.corners.isEmpty) continue;
      final d = (_codeCenter(r, size, frame) - tap).distance;
      if (d < bestDist) {
        bestDist = d;
        best = r;
      }
    }
    return bestDist <= _kPickRadius * 2 ? best : null;
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
      await WxScan.setResolution(next);
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = '${e.code}: ${e.message}');
    }
  }

  /// Decoding from the photo library, through the same Rust path the camera
  /// uses.
  Future<void> _pickFromGallery() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final outcome = await Scanner.scanImageBytes(bytes);
    if (!mounted) return;
    if (outcome.results.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No QR code found in the image')),
      );
      return;
    }
    _navigating = true;
    await WxScan.setScanning(false);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ResultPage(results: outcome.results),
      ),
    );
    _navigating = false;
    await WxScan.setScanning(true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Scanning stops in the background and resumes on return.
    if (state == AppLifecycleState.resumed) {
      WxScan.setScanning(!_navigating);
    } else {
      WxScan.setScanning(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _sizeSub?.cancel();
    WxScan.dispose();
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
        child: Stack(
        fit: StackFit.expand,
        children: [
          if (_camera != null) _buildPreview(_camera!),
          const _ScanFrameOverlay(),
          if (_lastFrame != null && _camera != null && _pickFrame == null)
            CustomPaint(
              painter: _CodeMarkerPainter(frame: _lastFrame!),
            ),
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
    );
  }

  Widget _buildPreview(WxScanCameraInfo info) {
    // The texture content is always upright with respect to the device's
    // natural orientation, so however far the screen turned is made up here,
    // and the box outside is sized to the dimensions after that. The two have
    // to agree, or BoxFit.cover stretches by the wrong ratio.
    final size = _previewSize ??
        WxPreviewSize(
            info.previewWidth, info.previewHeight, info.displayRotation);
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
              child: Texture(textureId: info.textureId),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const Text(
              'Scan',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            // The resolution step, raised by a tap. Useful when a dense
            // code will not come out.
            _chip(
              _resolution.label,
              onTap: _camera == null ? null : _cycleResolution,
              icon: Icons.hd_outlined,
            ),
            const SizedBox(width: 8),
            _chip(_nnEnabled ? 'CNN detection on' : 'Image processing only'),
          ],
        ),
      ),
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
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _zoom > 1
                    ? '${_zoom.toStringAsFixed(1)}x - pinch to zoom'
                    : 'Put the QR code in the frame to scan it',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_hasTorch)
                    IconButton.filledTonal(
                      onPressed: () async {
                        await WxScan.setTorch(!_torch);
                        setState(() => _torch = !_torch);
                      },
                      icon: Icon(
                        _torch ? Icons.flashlight_on : Icons.flashlight_off,
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

/// The viewfinder: four corners and a sweeping line.
class _ScanFrameOverlay extends StatefulWidget {
  const _ScanFrameOverlay();

  @override
  State<_ScanFrameOverlay> createState() => _ScanFrameOverlayState();
}

class _ScanFrameOverlayState extends State<_ScanFrameOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
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
        painter: _FramePainter(progress: _controller.value),
        size: Size.infinite,
      ),
    );
  }
}

class _FramePainter extends CustomPainter {
  final double progress;

  _FramePainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide * 0.68;
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2 - 30),
      width: side,
      height: side,
    );

    // Darken everything outside the frame.
    final overlay = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(12))),
    );
    canvas.drawPath(overlay, Paint()..color = Colors.black.withValues(alpha: 0.45));

    // The four corners.
    const green = Color(0xFF07C160);
    final corner = Paint()
      ..color = green
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const len = 24.0;
    void drawCorner(Offset o, double dx, double dy) {
      canvas.drawLine(o, o.translate(dx * len, 0), corner);
      canvas.drawLine(o, o.translate(0, dy * len), corner);
    }

    drawCorner(rect.topLeft, 1, 1);
    drawCorner(rect.topRight, -1, 1);
    drawCorner(rect.bottomLeft, 1, -1);
    drawCorner(rect.bottomRight, -1, -1);

    // The sweeping line.
    final y = rect.top + rect.height * progress;
    canvas.drawRect(
      Rect.fromLTWH(rect.left, y - 1, rect.width, 2),
      Paint()
        ..shader = const LinearGradient(
          colors: [Colors.transparent, green, Colors.transparent],
        ).createShader(Rect.fromLTWH(rect.left, y - 1, rect.width, 2)),
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) => old.progress != progress;
}

/// Radius of a marker, which is also the basis for tap hit-testing (the
/// tolerance is twice this).
const double _kPickRadius = 22;

/// What automatic zooming aims for: the code filling this fraction of the
/// picture's short side.
const double _kZoomTargetFraction = 0.45;

/// The ceiling for automatic zooming; beyond it the picture shakes too much
/// and the target is easily lost.
const double _kMaxAutoZoom = 4.0;

/// How long automatic zooming stands aside after a manual one.
const Duration _kManualZoomHold = Duration(seconds: 5);

/// How long automatic zooming waits after picking ends.
const Duration _kPickExitZoomHold = Duration(seconds: 3);

/// With one code decoded but more than one seen by detection, this is the
/// longest it waits for the second to come out so that picking can begin.
/// Failing that it takes the single code, rather than leaving the user
/// staring.
const Duration _kMultiCodeGrace = Duration(milliseconds: 700);

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

/// Frame coordinates to screen coordinates.
///
/// Mirroring needs no attention here: a desktop camera's preview is flipped,
/// but the flip and the coordinate mapping close over each other on the native
/// side -- the frame goes to the scanner as it is and Rust flips the
/// coordinates back through `mirror_output` -- so everything arriving here is
/// already in one coordinate system.
Offset _mapPoint(double x, double y, Size size, ScanOutcome f) {
  final m = _coverFit(size, f.width, f.height);
  return Offset(x * m.scale + m.dx, y * m.scale + m.dy);
}

/// A code's centre is the average of its four corners.
Offset _codeCenter(ScanResult r, Size size, ScanOutcome f) {
  final c = r.corners.centre;
  return _mapPoint(c.dx, c.dy, size, f);
}

/// Picking among several codes: darken the picture and put a marker with an
/// arrow on each one.
class _PickPainter extends CustomPainter {
  final ScanOutcome frame;

  _PickPainter({required this.frame});

  @override
  void paint(Canvas canvas, Size size) {
    if (frame.width == 0 || frame.height == 0) return;

    // Darken the whole screen so the markers stand out.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black.withValues(alpha: 0.5),
    );

    const green = Color(0xFF07C160);
    for (final r in frame.results) {
      if (r.corners.isEmpty) continue;

      // Outline where the code actually is, then put the button at its
      // centre. The two share one mapping, which makes a misplacement
      // obvious at a glance.
      final path = Path();
      for (var i = 0; i < r.corners.length; i++) {
        final p = _mapPoint(r.corners[i].dx, r.corners[i].dy, size, frame);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      path.close();
      canvas.drawPath(path, Paint()..color = green.withValues(alpha: 0.18));
      canvas.drawPath(
        path,
        Paint()
          ..color = green
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );

      final c = _codeCenter(r, size, frame);
      canvas.drawCircle(c, _kPickRadius + 6, Paint()..color = green.withValues(alpha: 0.25));
      canvas.drawCircle(c, _kPickRadius, Paint()..color = green);

      // A white arrow pointing right.
      final arrow = Paint()
        ..color = Colors.white
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      canvas.drawLine(c.translate(-4, -7), c.translate(4, 0), arrow);
      canvas.drawLine(c.translate(4, 0), c.translate(-4, 7), arrow);
    }
  }

  @override
  bool shouldRepaint(_PickPainter old) => old.frame != frame;
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
