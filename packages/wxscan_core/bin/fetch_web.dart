/// Puts the browser build's files where an application can serve them.
///
///     dart run wxscan_core:fetch_web              # into web/wxscan
///     dart run wxscan_core:fetch_web --into DIR
///     dart run wxscan_core:fetch_web --from DIR   # from a local build
///
/// The four files ship inside this package, so this copies rather than
/// downloads: no network, no release to keep in step, and the artifacts always
/// match the Dart that drives them. They are not assets — declaring Flutter
/// assets would make this a Flutter package, and `dart run` and `dart test`
/// would stop working — so they have to be placed by hand, which is what this
/// does.
///
/// A build hook cannot. Hooks emit code assets, which are native libraries the
/// Dart runtime loads, and a web build declares it wants none, so the hook
/// returns immediately. Data assets could carry these, but they are
/// experimental and bundled only by Flutter behind a flag. A hook also writes
/// into its own output directory, never into an application's `web/`.
library;

import 'dart:io';
import 'dart:isolate';

/// What the browser build needs served, in the order it is reported.
const _artifacts = [
  'wxscan_worker.js',
  'wxscan_wasm.wasm',
  'wxscan_tflite.js',
  'wxscan_tflite.wasm',
];

Future<int> main(List<String> args) async {
  if (args.contains('-h') || args.contains('--help')) {
    stdout.writeln(_usage);
    return 0;
  }

  final into = Directory(_option(args, '--into') ?? 'web/wxscan');
  final from = _option(args, '--from');

  final Directory source;
  if (from != null) {
    source = Directory(from);
  } else {
    final packageRoot = await _packageRoot();
    if (packageRoot == null) {
      stderr.writeln('wxscan_core: could not find the package. Run this from '
          'an application that depends on wxscan_core.');
      return 1;
    }
    source = Directory('${packageRoot.path}/lib/src/web/assets');
  }

  into.createSync(recursive: true);
  for (final name in _artifacts) {
    final file = File('${source.path}/$name');
    if (!file.existsSync()) {
      // A local build holds the three built artifacts; the worker script only
      // ever comes from the package.
      if (from != null && name == 'wxscan_worker.js') {
        final packageRoot = await _packageRoot();
        if (packageRoot != null) {
          File('${packageRoot.path}/lib/src/web/assets/$name')
              .copySync('${into.path}/$name');
          stdout.writeln('  $name  (from the package)');
          continue;
        }
      }
      stderr.writeln('wxscan_core: ${source.path} does not hold $name');
      return 1;
    }
    file.copySync('${into.path}/$name');
    stdout.writeln('  $name  ${_size(file)}');
  }

  stdout.writeln('\nPut into ${into.path}. If that is not `web/wxscan`, point '
      'the package at it with configureWxScanWeb() from '
      'package:wxscan_core/web.dart.');
  return 0;
}

const _usage = '''
Places the browser build's files for an application to serve.

  dart run wxscan_core:fetch_web [--into DIR] [--from DIR]

  --into DIR   where to put them; web/wxscan by default, which is where the
               package looks without being told otherwise
  --from DIR   take the WebAssembly artifacts from a local build instead of
               from this package: the output of tools/tflite-wasm/build.sh and
               of `cargo build -p wxscan-wasm --target wasm32-unknown-unknown`
               in the wxscan-rs repository
''';

String? _option(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

String _size(File file) {
  final kb = file.lengthSync() / 1024;
  return kb < 1024 ? '${kb.round()} KB' : '${(kb / 1024).toStringAsFixed(1)} MB';
}

/// This package's root.
///
/// Resolved through the package config rather than from `Platform.script`,
/// which under `dart run wxscan_core:fetch_web` points at a snapshot in
/// `.dart_tool` instead of at the package.
Future<Directory?> _packageRoot() async {
  final lib = await Isolate.resolvePackageUri(Uri.parse('package:wxscan_core/'));
  if (lib == null) return null;
  return Directory.fromUri(lib.resolve('..')).absolute;
}
