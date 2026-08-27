/// `fetch`, as much of it as this package needs.
library;

import 'dart:js_interop';
import 'dart:typed_data';

@JS('fetch')
external JSPromise<_Response> _fetch(String url);

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

/// Fetches [url], or returns null if the server said no.
Future<Uint8List?> httpGet(String url) async {
  final response = await _fetch(url).toDart;
  if (!response.ok) return null;
  return (await response.arrayBuffer().toDart).toDart.asUint8List();
}
