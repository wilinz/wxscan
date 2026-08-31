/// Decoding an encoded picture with the browser's own decoder.
///
/// The wasm build compiles no image decoders at all — `image-io` is off there,
/// since a browser has no filesystem and every kilobyte is served over the
/// network — so `scanImage` cannot go through the module the way the native
/// build does.
///
/// It does not need to. A browser already decodes pictures, and decodes more of
/// them than the native build: PNG, JPEG and GIF as there, plus WebP, AVIF and,
/// on Apple platforms, HEIC — the format the native path has to send back to
/// the caller. `createImageBitmap` reaches all of it, at no cost in module
/// size.
///
/// `imageOrientation: 'from-image'` is what makes this agree with the native
/// path, which applies the orientation the file records. Without it a
/// photograph taken sideways would come back on its side here and upright
/// everywhere else, and the coordinates with it.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSAny> parts);
}

@JS('createImageBitmap')
external JSPromise<_ImageBitmap> _createImageBitmap(
  _Blob blob,
  JSObject options,
);

extension type _ImageBitmap._(JSObject _) implements JSObject {
  external int get width;
  external int get height;
  external void close();
}

@JS('OffscreenCanvas')
extension type _OffscreenCanvas._(JSObject _) implements JSObject {
  external factory _OffscreenCanvas(int width, int height);
  external _Context? getContext(String contextId);
}

extension type _Context._(JSObject _) implements JSObject {
  external void drawImage(_ImageBitmap image, int dx, int dy);
  external _ImageData getImageData(int sx, int sy, int sw, int sh);
}

extension type _ImageData._(JSObject _) implements JSObject {
  external JSUint8ClampedArray get data;
}

/// An encoded picture decoded to RGBA.
class DecodedImage {
  const DecodedImage(this.pixels, this.width, this.height);

  final Uint8List pixels;
  final int width;
  final int height;
}

/// Decodes [data] with the browser, or returns null if it is not a picture the
/// browser can read.
///
/// The bitmap is released whatever happens: it holds decoded pixels outside the
/// Dart heap, and the garbage collector has no way to know how large it is.
Future<DecodedImage?> decodeImage(Uint8List data) async {
  final options = JSObject()
    ..setProperty('imageOrientation'.toJS, 'from-image'.toJS);

  final _ImageBitmap bitmap;
  try {
    bitmap = await _createImageBitmap(_Blob([data.toJS].toJS), options).toDart;
  } catch (_) {
    // The browser rejects what it cannot decode, which is the same answer the
    // native path gives as UnsupportedFormat rather than an exception type of
    // its own.
    return null;
  }

  try {
    final width = bitmap.width;
    final height = bitmap.height;
    if (width <= 0 || height <= 0) return null;

    final context = _OffscreenCanvas(width, height).getContext('2d');
    if (context == null) return null;
    context.drawImage(bitmap, 0, 0);
    final pixels = context.getImageData(0, 0, width, height).data.toDart;
    return DecodedImage(pixels.buffer.asUint8List(), width, height);
  } finally {
    bitmap.close();
  }
}
