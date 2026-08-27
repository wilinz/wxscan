/// The camera, in a browser.
///
/// `getUserMedia` gives a `MediaStream`; a `<video>` plays it and is what the
/// preview shows, and a canvas takes a still of each frame for the scanner.
/// Torch and zoom are track constraints, which browsers support unevenly, so
/// both are reported as absent rather than assumed.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

@JS('navigator.mediaDevices.getUserMedia')
external JSPromise<JSObject> _getUserMedia(JSObject constraints);

@JS('document.createElement')
external JSObject _createElement(String tag);

extension type _Video(JSObject _) implements JSObject {
  external set srcObject(JSObject? value);
  external set autoplay(bool value);
  external set muted(bool value);
  external int get videoWidth;
  external int get videoHeight;
  external JSPromise<JSAny?> play();
}

extension type _Canvas(JSObject _) implements JSObject {
  external set width(int value);
  external set height(int value);
  external JSObject? getContext(String kind, [JSObject options]);
  external JSString toDataURL(String type, double quality);
}

extension type _Context(JSObject _) implements JSObject {
  external void drawImage(JSObject image, int x, int y, int w, int h);
  external JSObject getImageData(int x, int y, int w, int h);
}

/// One frame, as the scanner wants it: RGBA, tightly packed.
class WxFrame {
  const WxFrame(this.pixels, this.width, this.height);

  final Uint8List pixels;
  final int width;
  final int height;
}

/// A camera session: the stream, the element showing it, and the canvas its
/// frames are read through.
class WxCamera {
  WxCamera._(this._stream, this.video, this._canvas, this._context);

  final JSObject _stream;

  /// The element the preview platform view shows.
  final _Video video;

  final _Canvas _canvas;
  final _Context _context;

  var _width = 0, _height = 0;

  /// Whether a frame request is outstanding, what it will call, and the one
  /// JS wrapper it goes through. See [onFrame].
  var _armed = false;
  void Function()? _ready;
  JSFunction? _frameCallback;

  int get width => video.videoWidth;
  int get height => video.videoHeight;

  /// Opens the rear camera at roughly [shortSide] pixels on its short side.
  ///
  /// The size is a request: a browser gives what the device has, and frames
  /// are read at whatever it settles on.
  static Future<WxCamera> open(int shortSide) async {
    final video = JSObject()..setProperty('facingMode'.toJS, 'environment'.toJS);
    if (shortSide > 0) {
      video.setProperty(
          'height'.toJS, JSObject()..setProperty('ideal'.toJS, shortSide.toJS));
    }
    final constraints = JSObject()
      ..setProperty('video'.toJS, video)
      ..setProperty('audio'.toJS, false.toJS);

    final stream = await _getUserMedia(constraints).toDart;

    final element = _Video(_createElement('video'))
      ..autoplay = true
      ..muted = true
      ..srcObject = stream;
    // Safari will not play a video inline unless told, and the element has to
    // fill whatever the platform view is given.
    element
      ..setProperty('playsInline'.toJS, true.toJS)
      ..setProperty(
          'style'.toJS, 'width:100%;height:100%;object-fit:cover'.toJS);
    await element.play().toDart;
    await _waitForSize(element);

    final canvas = _Canvas(_createElement('canvas'));
    // Without this a browser keeps the canvas on the GPU, and every frame's
    // `getImageData` waits on a readback across that boundary — the one part
    // of a scan that runs on the page's own thread, and so the one that shows
    // up as a stutter in the preview.
    final options = JSObject()
      ..setProperty('willReadFrequently'.toJS, true.toJS);
    return WxCamera._(
        stream, element, canvas, _Context(canvas.getContext('2d', options)!));
  }

  /// Waits for the video to know its size, which it does not at `play`.
  static Future<void> _waitForSize(_Video video) async {
    for (var i = 0; i < 100 && video.videoWidth == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Reads the current frame as RGBA, or null before the first one arrives.
  WxFrame? grab() {
    final w = video.videoWidth, h = video.videoHeight;
    if (w == 0 || h == 0) return null;
    // Assigning either dimension clears the canvas and reallocates its backing
    // store, so it is done only when the track's size actually changes.
    if (w != _width || h != _height) {
      _canvas
        ..width = w
        ..height = h;
      _width = w;
      _height = h;
    }
    _context.drawImage(video, 0, 0, w, h);
    final data = _context.getImageData(0, 0, w, h);
    final pixels = data.getProperty<JSUint8Array>('data'.toJS).toDart;
    return WxFrame(pixels, w, h);
  }

  /// The current frame as a JPEG, for a frozen picture.
  Uint8List? jpeg() {
    if (grab() == null) return null;
    final url = _canvas.toDataURL('image/jpeg', 0.9).toDart;
    final comma = url.indexOf(',');
    return comma < 0 ? null : _base64(url.substring(comma + 1));
  }

  /// Calls [ready] once, when the track has a frame the page has not seen.
  ///
  /// `requestVideoFrameCallback` is what a browser uses to say a new frame has
  /// been presented. Driving the pump from it means no frame is ever scanned
  /// twice — a wasted scan costs as much as a real one — and none is scanned
  /// stale. Where it is missing the caller falls back to its timer, which is
  /// why this reports whether it took the request.
  ///
  /// At most one request stands at a time, and the callback crossing to JS is
  /// made once: asking again while one is outstanding replaces what it will
  /// call, and nothing more. Both matter because this is asked every frame —
  /// two callers can end up asking for the same camera, and each would
  /// otherwise leave behind a chain of its own and a `toJS` wrapper the engine
  /// never collects.
  bool onFrame(void Function() ready) {
    if (!video.has('requestVideoFrameCallback')) return false;
    _ready = ready;
    if (_armed) return true;
    _armed = true;
    _frameCallback ??= ((JSAny? _, JSAny? __) {
      _armed = false;
      _ready?.call();
    }).toJS;
    video.callMethod<JSAny?>('requestVideoFrameCallback'.toJS, _frameCallback!);
    return true;
  }

  JSObject? _track() {
    final tracks =
        _stream.callMethod<JSArray<JSObject>>('getVideoTracks'.toJS).toDart;
    return tracks.isEmpty ? null : tracks.first;
  }

  JSObject? _capabilities() =>
      _track()?.callMethod<JSObject?>('getCapabilities'.toJS);

  /// Whether the track says it has a torch. Most browsers say nothing.
  bool get hasTorch => _capabilities()?.has('torch') ?? false;

  /// Turns the torch on or off, where there is one.
  Future<void> setTorch(bool on) async {
    final track = _track();
    if (track == null || !hasTorch) return;
    await _apply(track, 'torch', on.toJS);
  }

  /// The zoom range the track reports, or null where it reports none.
  ({double min, double max})? zoomRange() {
    final capabilities = _capabilities();
    if (capabilities == null || !capabilities.has('zoom')) return null;
    final zoom = capabilities.getProperty<JSObject>('zoom'.toJS);
    return (
      min: zoom.getProperty<JSNumber>('min'.toJS).toDartDouble,
      max: zoom.getProperty<JSNumber>('max'.toJS).toDartDouble,
    );
  }

  /// Sets the zoom, returning what was actually applied.
  Future<double> setZoom(double ratio) async {
    final track = _track();
    final range = zoomRange();
    if (track == null || range == null) return 1;
    final clamped = ratio.clamp(range.min, range.max);
    await _apply(track, 'zoom', clamped.toJS);
    return clamped;
  }

  Future<void> _apply(JSObject track, String name, JSAny value) async {
    final one = JSObject()..setProperty(name.toJS, value);
    final constraints = JSObject()
      ..setProperty('advanced'.toJS, <JSObject>[one].toJS);
    await track
        .callMethod<JSPromise<JSAny?>>('applyConstraints'.toJS, constraints)
        .toDart;
  }

  /// Stops the camera. The indicator light goes out here.
  void close() {
    for (final track
        in _stream.callMethod<JSArray<JSObject>>('getVideoTracks'.toJS).toDart) {
      track.callMethod<JSAny?>('stop'.toJS);
    }
    video.srcObject = null;
  }
}

/// Decodes the base64 half of a data URL.
Uint8List _base64(String data) {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final out = <int>[];
  var buffer = 0, bits = 0;
  for (final unit in data.codeUnits) {
    final value = alphabet.indexOf(String.fromCharCode(unit));
    if (value < 0) continue;
    buffer = (buffer << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xff);
    }
  }
  return Uint8List.fromList(out);
}
