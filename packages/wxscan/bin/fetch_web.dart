/// Puts the browser build's files where an application can serve them.
///
///     dart run wxscan:fetch_web              # into web/wxscan
///     dart run wxscan:fetch_web --into DIR
///     dart run wxscan:fetch_web --from DIR   # from a local build
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

/// What the browser build needs served, and where each one comes from.
///
/// The scanner is deliberately *not* bundled. It is the one file here built
/// from the Rust sources, and a compiled artifact committed beside the sources
/// it came from goes quietly out of step with them — which is exactly what it
/// did: the live demo served a detector bug for a while after Rust had been
/// fixed, because rebuilding it was a step someone had to remember. Anything
/// that has to be remembered eventually is not.
///
/// The other three stay. The worker is hand-written and moves with this
/// package rather than with Rust, and the TensorFlow Lite runtime is an
/// emscripten build of TensorFlow and a thousand XNNPACK microkernels — a
/// quarter of an hour, and an emsdk — that moves only when the pinned TFLite
/// version does. Asking for that to try a package would be asking too much;
/// asking for one `cargo build` is not.
enum _Artifact {
  worker('wxscan_worker.js', bundled: true),
  scanner('wxscan_wasm.wasm', bundled: false),
  tfliteJs('wxscan_tflite.js', bundled: true),
  tfliteWasm('wxscan_tflite.wasm', bundled: true);

  const _Artifact(this.name, {required this.bundled});

  final String name;

  /// Whether this package carries a copy, and so whether `--from` is the only
  /// way to get one.
  final bool bundled;
}

/// The Dart VM ignores whatever `main` returns, so the status has to be set
/// rather than returned. Without this every failure below left the process
/// reporting success, which a script — or a CI step that now depends on the
/// scanner being built — would never notice.
Future<void> main(List<String> args) async {
  exitCode = await _run(args);
}

Future<int> _run(List<String> args) async {
  if (args.contains('-h') || args.contains('--help')) {
    stdout.writeln(_usage);
    return 0;
  }

  final into = Directory(_option(args, '--into') ?? 'web/wxscan');
  final from = _option(args, '--from');

  final packageRoot = await _packageRoot();
  if (packageRoot == null) {
    stderr.writeln('wxscan: could not find the package. Run this from '
        'an application that depends on wxscan.');
    return 1;
  }
  final bundled = Directory('${packageRoot.path}/lib/src/web/assets');

  // Every source is resolved before anything is written, so a missing
  // scanner does not leave three of the four files in place and the served
  // directory in a state that looks half done.
  final sources = <_Artifact, (File, String)>{};
  for (final artifact in _Artifact.values) {
    // A local build wins wherever it has the file, so building only the
    // scanner — which is the usual case — takes the rest from the package.
    final built = from == null ? null : File('$from/${artifact.name}');
    if (built != null && built.existsSync()) {
      sources[artifact] = (built, _size(built));
      continue;
    }
    if (!artifact.bundled) {
      stderr.writeln(_notBundled(artifact.name, from));
      return 1;
    }
    final file = File('${bundled.path}/${artifact.name}');
    if (!file.existsSync()) {
      stderr.writeln('wxscan: ${file.path} is missing');
      return 1;
    }
    sources[artifact] = (file, '${_size(file)}  (from the package)');
  }

  into.createSync(recursive: true);
  for (final MapEntry(key: artifact, value: (file, where)) in sources.entries) {
    file.copySync('${into.path}/${artifact.name}');
    stdout.writeln('  ${artifact.name}  $where');
  }

  stdout.writeln('\nPut into ${into.path}. If that is not `web/wxscan`, point '
      'the package at it with configureWxScanWeb() from '
      'package:wxscan/web.dart.');
  return 0;
}

const _usage = '''
Places the browser build's files for an application to serve.

  dart run wxscan:fetch_web [--into DIR] [--from DIR]

  --into DIR   where to put them; web/wxscan by default, which is where the
               package looks without being told otherwise
  --from DIR   take whatever this directory holds from a local build instead
               of from the package. The scanner (wxscan_wasm.wasm) is not
               bundled and has to come from here; run it with no --from to be
               told how to build it.
''';

/// What to say when the one artifact this package does not carry is not to
/// hand either. It is the whole of the reader's next step, because they have
/// no other way to find it out.
String _notBundled(String name, String? from) => '''
wxscan: $name is not bundled with this package${from == null ? '' : ', and $from does not hold it'}.

  It is built from the Rust sources rather than committed, so that it cannot
  fall out of step with them. Building it is one command:

      git clone https://github.com/wilinz/wxscan-rs
      git clone https://github.com/wilinz/cvlite
      git clone https://github.com/wilinz/wxing
      cd wxscan-rs
      printf '[patch.crates-io]\\ncvlite = { path = "../cvlite" }\\nwxing = { path = "../wxing" }\\n' \\
        > .cargo/config.toml
      RUSTFLAGS="-C target-feature=+simd128" cargo build -p wxscan-wasm \\
        --target wasm32-unknown-unknown --profile wasm

  The two siblings are cloned because cvlite and wxing are not on crates.io
  yet. Then point this at the output:

      dart run wxscan:fetch_web --from wxscan-rs/target/wasm32-unknown-unknown/wasm

  The other three files come from the package, so nothing else has to be built.
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
/// which under `dart run wxscan:fetch_web` points at a snapshot in
/// `.dart_tool` instead of at the package.
Future<Directory?> _packageRoot() async {
  final lib = await Isolate.resolvePackageUri(Uri.parse('package:wxscan/'));
  if (lib == null) return null;
  return Directory.fromUri(lib.resolve('..')).absolute;
}
