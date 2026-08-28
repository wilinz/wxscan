/// Where the weights live once they are files.
///
/// A Flutter asset is not a file: it lives inside the application package and
/// has no path to open. The path form of `WxScanner.create` wants one, so the
/// two weights are copied out of the bundle into the sandbox the first time
/// the application runs, and every run after that opens them by path and never
/// holds a megabyte in Dart at all.
///
/// A browser has neither a sandbox nor a path, so its half of this throws and
/// [Scanner] keeps to the bytes there.
library;

export 'model_files_io.dart'
    if (dart.library.js_interop) 'model_files_web.dart';
