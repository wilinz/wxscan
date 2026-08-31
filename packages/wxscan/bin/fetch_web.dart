/// Puts the browser build's files where an application can serve them.
///
///     dart run wxscan:fetch_web              # into web/wxscan
///     dart run wxscan:fetch_web --into DIR
///     dart run wxscan:fetch_web --from DIR   # from a local build
///     dart run wxscan:fetch_web --offline    # cache only, never the network
///
/// Three of the four files are compiled — the scanner from the Rust sources,
/// and the TensorFlow Lite runtime's two by emscripten — and none of them is
/// carried in this package. A compiled artifact sitting beside the sources it
/// came from goes out of step with them, and one here did: the live demo served
/// a detector bug for a while after Rust had been fixed, because rebuilding it
/// was a step someone had to remember. Anything that has to be remembered
/// eventually is not.
///
/// So they are built by CI and fetched from releases, pinned by repository,
/// tag and checksum in `tool/web.lock`. Two repositories rather than one,
/// because the two move on different rhythms: the scanner is wxscan-rs's own
/// code and changes with every push there, while the runtime is a dependency
/// built in wxscan-litert-wasm and moves only when the pinned TensorFlow
/// version or the patches on top of it do — many scanner versions point at one
/// runtime. Nothing has to be built to use this package in a browser, and
/// nothing can quietly rot either.
///
/// The fourth comes from here: `wxscan_worker.js` is hand-written and moves
/// with this package rather than with Rust.
///
/// They are files rather than declared Flutter assets because declaring assets
/// would make this a Flutter package, and `dart run` and `dart test` would stop
/// working. A build hook cannot place them either: hooks emit code assets,
/// which are libraries the Dart runtime loads, and a web build declares it
/// wants none, so the hook returns immediately. A hook also writes into its own
/// output directory, never into an application's `web/`.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// What the browser build needs served, and where each one comes from.
enum _Artifact {
  worker('wxscan_worker.js', from: _Source.package),
  scanner('wxscan_wasm.wasm', from: _Source.scannerRelease),
  tfliteJs('wxscan_tflite.js', from: _Source.tfliteRelease),
  tfliteWasm('wxscan_tflite.wasm', from: _Source.tfliteRelease);

  const _Artifact(this.name, {required this.from});

  final String name;
  final _Source from;
}

/// The three places a file can come from. `--from` overrides all of them,
/// wherever it happens to hold the file.
enum _Source { package, scannerRelease, tfliteRelease }

Future<void> main(List<String> args) async {
  // The Dart VM ignores whatever `main` returns, so the status has to be set
  // rather than returned. Without this every failure below would leave the
  // process reporting success, which a build script would never notice.
  exitCode = await _run(args);
}

Future<int> _run(List<String> args) async {
  if (args.contains('-h') || args.contains('--help')) {
    stdout.writeln(_usage);
    return 0;
  }

  final into = Directory(_option(args, '--into') ?? 'web/wxscan');
  final from = _option(args, '--from');
  final offline = args.contains('--offline');

  final packageRoot = await _packageRoot();
  if (packageRoot == null) {
    stderr.writeln(
      'wxscan: could not find the package. Run this from '
      'an application that depends on wxscan.',
    );
    return 1;
  }
  final bundled = Directory('${packageRoot.path}/lib/src/web/assets');

  final _Lock lock;
  try {
    lock = _Lock.read(File('${packageRoot.path}/tool/web.lock'));
  } on FormatException catch (e) {
    stderr.writeln('wxscan: ${e.message}');
    return 1;
  }

  // Downloads are kept between runs, keyed by the checksum they must have, so
  // a second project on the same machine pays nothing, and a re-run after a
  // failure pays nothing either.
  final cache = Directory('${_cacheRoot()}/wxscan/web');

  // Every source is resolved before anything is written, so a file that cannot
  // be had does not leave the served directory looking half finished.
  final sources = <_Artifact, (File, String)>{};
  for (final artifact in _Artifact.values) {
    // A local build wins wherever it has the file, so building only the
    // scanner takes the rest from the package and the releases.
    final built = from == null ? null : File('$from/${artifact.name}');
    if (built != null && built.existsSync()) {
      sources[artifact] = (built, '${_size(built)}  (from $from)');
      continue;
    }

    if (artifact.from == _Source.package) {
      final file = File('${bundled.path}/${artifact.name}');
      if (!file.existsSync()) {
        stderr.writeln('wxscan: ${file.path} is missing');
        return 1;
      }
      sources[artifact] = (file, '${_size(file)}  (from the package)');
      continue;
    }

    final (repo, tag, want) = lock.pin(artifact);
    final File file;
    try {
      file = await _fetch(
        repo: repo,
        tag: tag,
        name: artifact.name,
        want: want,
        cache: cache,
        offline: offline,
      );
    } on _FetchFailure catch (e) {
      stderr.writeln(e.message);
      return 1;
    }
    sources[artifact] = (file, '${_size(file)}  ($tag)');
  }

  into.createSync(recursive: true);
  for (final MapEntry(key: artifact, value: (file, where)) in sources.entries) {
    file.copySync('${into.path}/${artifact.name}');
    stdout.writeln('  ${artifact.name}  $where');
  }

  stdout.writeln(
    '\nPut into ${into.path}. If that is not `web/wxscan`, point '
    'the package at it with configureWxScanWeb() from '
    'package:wxscan/web.dart.',
  );
  return 0;
}

/// Gets one release asset, from the cache if it is already there.
///
/// The checksum names the file in the cache as well as guaranteeing it: a hit
/// is a file already known to be the right one, so nothing is verified twice,
/// and a pin that changes cannot be answered by a stale copy.
Future<File> _fetch({
  required String repo,
  required String tag,
  required String name,
  required String want,
  required Directory cache,
  required bool offline,
}) async {
  final cached = File('${cache.path}/$want/$name');
  if (cached.existsSync()) return cached;

  final url = 'https://github.com/$repo/releases/download/$tag/$name';
  if (offline) {
    throw _FetchFailure(
      'wxscan: $name is not in the cache and --offline was '
      'given.\n  It would have come from $url',
    );
  }

  stdout.writeln('  fetching $name from $tag');
  final bytes = await _get(url);

  final got = sha256.convert(bytes).toString();
  if (got != want) {
    throw _FetchFailure(
      '''
wxscan: $name is not what tool/web.lock pins.
  from     $url
  pinned   $want
  received $got

  A release asset can be replaced, so nothing here uses bytes the lock does not
  name. If the release changed on purpose, re-pin it with tool/stamp_web.sh.''',
    );
  }

  cached.parent.createSync(recursive: true);
  // Written beside and moved into place, so an interrupted run cannot leave a
  // truncated file under a name that says it has been checked.
  File('${cached.path}.part')
    ..writeAsBytesSync(bytes)
    ..renameSync(cached.path);
  return cached;
}

Future<List<int>> _get(String url) async {
  final client = HttpClient();
  try {
    final response = await client.getUrl(Uri.parse(url)).then((r) => r.close());
    if (response.statusCode != 200) {
      throw _FetchFailure(
        'wxscan: $url answered ${response.statusCode}.\n'
        '  The tag in tool/web.lock may not exist, or may not carry this '
        'asset.',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return bytes;
  } on SocketException catch (e) {
    throw _FetchFailure('wxscan: could not reach $url ($e)');
  } finally {
    client.close();
  }
}

class _FetchFailure implements Exception {
  const _FetchFailure(this.message);
  final String message;
}

/// `tool/web.lock`: the whole of what this package trusts about the two
/// artifacts it does not carry.
class _Lock {
  const _Lock({
    required this.scannerRepo,
    required this.scannerTag,
    required this.scannerSha,
    required this.tfliteRepo,
    required this.tfliteTag,
    required this.tfliteJsSha,
    required this.tfliteWasmSha,
  });

  final String scannerRepo, scannerTag, scannerSha;
  final String tfliteRepo, tfliteTag, tfliteJsSha, tfliteWasmSha;

  static _Lock read(File file) {
    if (!file.existsSync()) throw FormatException('${file.path} is missing');
    final values = <String, String>{};
    for (final line in file.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final i = trimmed.indexOf('=');
      if (i > 0) values[trimmed.substring(0, i)] = trimmed.substring(i + 1);
    }
    String need(String key) =>
        values[key] ?? (throw FormatException('${file.path} has no $key'));
    return _Lock(
      scannerRepo: need('SCANNER_REPO'),
      scannerTag: need('SCANNER_TAG'),
      scannerSha: need('SCANNER_SHA256'),
      tfliteRepo: need('TFLITE_REPO'),
      tfliteTag: need('TFLITE_TAG'),
      tfliteJsSha: need('TFLITE_JS_SHA256'),
      tfliteWasmSha: need('TFLITE_WASM_SHA256'),
    );
  }

  (String, String, String) pin(_Artifact artifact) => switch (artifact) {
    _Artifact.scanner => (scannerRepo, scannerTag, scannerSha),
    _Artifact.tfliteJs => (tfliteRepo, tfliteTag, tfliteJsSha),
    _Artifact.tfliteWasm => (tfliteRepo, tfliteTag, tfliteWasmSha),
    _Artifact.worker => throw StateError('the worker is not fetched'),
  };
}

/// Where downloads are kept between runs.
///
/// Outside the project, so several checkouts share one copy, and under the
/// platform's own cache directory so that clearing caches clears this too.
String _cacheRoot() {
  final env = Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
  if (Platform.isWindows) return env['LOCALAPPDATA'] ?? '$home/AppData/Local';
  if (Platform.isMacOS) return '$home/Library/Caches';
  return env['XDG_CACHE_HOME'] ?? '$home/.cache';
}

const _usage = '''
Places the browser build's files for an application to serve.

  dart run wxscan:fetch_web [--into DIR] [--from DIR] [--offline]

  --into DIR   where to put them; web/wxscan by default, which is where the
               package looks without being told otherwise
  --from DIR   take whatever this directory holds from a local build instead
               of from the package or a release. Building the scanner and
               pointing this at it is how to try a change to the Rust without
               waiting for a release.
  --offline    use only what has already been downloaded, and fail rather than
               reach the network

The scanner and the TensorFlow Lite runtime are not carried in this package.
They are fetched from the releases named in tool/web.lock, checked against the
checksums there, and kept in a cache between runs.
''';

String? _option(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

String _size(File file) {
  final kb = file.lengthSync() / 1024;
  return kb < 1024
      ? '${kb.round()} KB'
      : '${(kb / 1024).toStringAsFixed(1)} MB';
}

/// This package's root.
///
/// Resolved through the package config rather than from `Platform.script`,
/// which under `dart run wxscan:fetch_web` points at a snapshot in
/// `.dart_tool` instead of at the package.
Future<Directory?> _packageRoot() async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:wxscan/'));
  if (uri == null) return null;
  return Directory.fromUri(uri.resolve('..'));
}
