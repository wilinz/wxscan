/// Talking to the scanner in its worker.
///
/// The whole engine — both WebAssembly modules — runs in a worker, so a scan
/// does not block the page. What crosses the boundary is a frame going in, as
/// a transferred buffer that costs nothing to hand over, and a JSON document
/// coming back. The C ABI's results cannot cross it: they are pointers into
/// the worker's memory.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../result.dart';
import '../frame_json.dart';

@JS('Worker')
extension type _Worker._(JSObject _) implements JSObject {
  external factory _Worker(String url, JSObject options);
  external void postMessage(JSAny message, JSArray<JSObject> transfer);
  external void terminate();
  external set onmessage(JSFunction handler);
  external set onerror(JSFunction handler);
}

extension type _Message._(JSObject _) implements JSObject {
  external JSAny? get data;
}

/// A scanner running in a worker.
class WxScanWorker {
  WxScanWorker._(this._worker);

  final _Worker _worker;
  final _pending = <int, Completer<JSObject>>{};
  var _nextId = 0;
  var _closed = false;

  /// Whether the CNN detector loaded.
  var hasDetector = false;

  /// Whether super resolution loaded.
  var hasSuperResolution = false;

  /// Starts a worker and gives it everything it needs.
  ///
  /// [workerUrl] is this package's `wxscan_worker.js`, [wxscanWasm] the
  /// scanner module. [tfliteUrl] and the two weight buffers are the inference
  /// host; without them the worker still decodes, but the CNN stages are gone
  /// and small or distant symbols are found far less often.
  static Future<WxScanWorker> start({
    required String workerUrl,
    required Uint8List wxscanWasm,
    String? tfliteUrl,
    Uint8List? detectModel,
    Uint8List? srModel,
  }) async {
    final options = JSObject()..setProperty('type'.toJS, 'module'.toJS);
    final client = WxScanWorker._(_Worker(workerUrl, options));
    client._listen();

    final withModels =
        tfliteUrl != null && detectModel != null && srModel != null;
    final reply = await client._send(
      'init',
      (message) {
        message.setProperty('wxscan'.toJS, wxscanWasm.buffer.toJS);
        if (withModels) {
          message
            ..setProperty('tflite'.toJS, tfliteUrl.toJS)
            ..setProperty('detect'.toJS, detectModel.buffer.toJS)
            ..setProperty('sr'.toJS, srModel.buffer.toJS);
        }
      },
      // Copied rather than transferred, unlike a frame. These buffers belong
      // to the caller, who has every reason to keep them — the camera plugin
      // and a still-image scanner in one application are handed the same
      // weights — and transferring would empty them on the way out.
    );
    client.hasDetector = reply
        .getProperty<JSBoolean>('hasDetector'.toJS)
        .toDart;
    client.hasSuperResolution = reply
        .getProperty<JSBoolean>('hasSuperResolution'.toJS)
        .toDart;
    return client;
  }

  void _listen() {
    _worker.onmessage = ((_Message event) {
      final data = event.data as JSObject;
      final id = data.getProperty<JSNumber>('id'.toJS).toDartInt;
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (data.getProperty<JSBoolean>('ok'.toJS).toDart) {
        completer.complete(data);
      } else {
        completer.completeError(
          StateError(
            'wxscan: ${data.getProperty<JSString>('error'.toJS).toDart}',
          ),
        );
      }
    }).toJS;
    _worker.onerror = ((JSObject event) {
      final failure = StateError('wxscan: the scanner worker failed');
      for (final completer in _pending.values.toList()) {
        completer.completeError(failure);
      }
      _pending.clear();
    }).toJS;
  }

  Future<JSObject> _send(
    String command,
    void Function(JSObject message) fill, {
    List<JSObject> transfer = const [],
  }) {
    if (_closed) {
      throw StateError('wxscan: this scanner has been disposed');
    }
    final id = _nextId++;
    final completer = Completer<JSObject>();
    _pending[id] = completer;
    final message = JSObject()
      ..setProperty('id'.toJS, id.toJS)
      ..setProperty('cmd'.toJS, command.toJS);
    fill(message);
    _worker.postMessage(message, transfer.toJS);
    return completer.future;
  }

  /// Runs one of the scan commands.
  ///
  /// The pixel buffer is **transferred**, not copied, which is what makes a
  /// frame free to hand over and leaves the caller's view of it empty. Every
  /// entry point below is called either with a buffer its caller owns outright
  /// — a frame straight from a canvas — or with a copy made for the purpose.
  Future<ScanOutcome> _scan(
    String command,
    Uint8List pixels,
    int width,
    int height, [
    void Function(JSObject message)? extra,
  ]) async {
    final json = await _scanJson(command, pixels, width, height, extra);
    return json == null ? ScanOutcome.empty : parseFrameJson(json);
  }

  /// As [_scan], but stopping at the document.
  ///
  /// The camera plugin forwards this as it stands: its own event stream is
  /// already a stream of these, from the platform bindings that produce them
  /// natively, so parsing here and re-encoding there would be waste.
  Future<String?> _scanJson(
    String command,
    Uint8List pixels,
    int width,
    int height,
    void Function(JSObject message)? extra,
  ) async {
    final buffer = pixels.buffer;
    final reply = await _send(command, (message) {
      message
        ..setProperty('pixels'.toJS, buffer.toJS)
        ..setProperty('width'.toJS, width.toJS)
        ..setProperty('height'.toJS, height.toJS);
      extra?.call(message);
    }, transfer: [buffer.toJS]);
    return reply.getProperty<JSString?>('json'.toJS)?.toDart;
  }

  /// Decodes a colour image and hands back the document itself, for a caller
  /// that forwards documents.
  Future<String?> scanPixelsJson(
    Uint8List pixels,
    int width,
    int height,
    int format,
  ) => _scanJson(
    'scanPixels',
    pixels,
    width,
    height,
    (m) => m.setProperty('format'.toJS, format.toJS),
  );

  /// Decodes an upright, tightly packed grayscale image.
  Future<ScanOutcome> scanGray(Uint8List gray, int width, int height) =>
      _scan('scanGray', gray, width, height);

  /// Decodes a colour image, converting it to grayscale first. [format] is a
  /// `WxScanPixelFormat` value.
  Future<ScanOutcome> scanPixels(
    Uint8List pixels,
    int width,
    int height,
    int format,
  ) => _scan(
    'scanPixels',
    pixels,
    width,
    height,
    (m) => m.setProperty('format'.toJS, format.toJS),
  );

  /// Decodes a camera frame: a Y plane with a row stride, rotated upright.
  Future<ScanOutcome> scanFrame(
    Uint8List plane,
    int width,
    int height, {
    required int rowStride,
    required int rotation,
    required bool mirror,
  }) => _scan('scanFrame', plane, width, height, (m) {
    m
      ..setProperty('rowStride'.toJS, rowStride.toJS)
      ..setProperty('rotation'.toJS, rotation.toJS)
      ..setProperty('mirror'.toJS, mirror.toJS);
  });

  /// Stops the worker. Using it afterwards throws.
  Future<void> dispose() async {
    if (_closed) return;
    try {
      await _send('dispose', (_) {});
    } catch (_) {
      // A worker that has already died needs no telling.
    }
    _closed = true;
    _worker.terminate();
  }
}
