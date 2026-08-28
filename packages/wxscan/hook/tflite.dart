/// Fetching the prebuilt TFLite C library.
///
/// The library is not kept in the repository: it is 1.5 MB per desktop platform
/// and 5 MB per Android ABI. Each artifact is pinned by version and SHA-256 in
/// `tool/tflite.lock`; a mismatch fails the build.
///
/// Sources:
///   Android  Google Maven, com.google.ai.edge.litert:litert (official)
///   iOS      the release channel CocoaPods pulls from (a static framework)
///   desktop  CI builds of the TensorFlow sources (there is no official desktop
///            distribution); the repository is named in tflite.lock
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';

/// What a platform's TFLite artifact turned into on disk.
class TfliteLibrary {
  TfliteLibrary({required this.file, required this.linkName, required this.isStatic});

  /// The extracted library.
  final File file;

  /// The name to pass to the linker, without the `lib` prefix or extension.
  /// Android's distribution calls it LiteRt rather than tensorflowlite_c.
  final String linkName;

  /// iOS ships a static framework, which is linked into the Rust library
  /// instead of being bundled beside it.
  final bool isStatic;

  Directory get directory => file.parent;
}

/// Reads `tool/tflite.lock`, the pinned list of artifacts.
///
/// Keeping it a flat `KEY=value` file means the shell scripts, had they stayed,
/// and this hook would read the same source of truth, and an upgrade is one
/// file to edit.
Map<String, String> readLock(Directory packageRoot) {
  final file = File.fromUri(packageRoot.uri.resolve('tool/tflite.lock'));
  if (!file.existsSync()) {
    throw StateError('wxscan: missing ${file.path}');
  }
  final lock = <String, String>{};
  for (final line in const LineSplitter().convert(file.readAsStringSync())) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final eq = trimmed.indexOf('=');
    if (eq > 0) lock[trimmed.substring(0, eq)] = trimmed.substring(eq + 1);
  }
  return lock;
}

/// Downloads and extracts the library for [os] and [architecture].
///
/// Everything lands under [cache], which the hook runner keeps between builds,
/// so a rebuild re-uses what is already there.
Future<TfliteLibrary> fetchTflite({
  required OS os,
  required Architecture architecture,
  required Directory packageRoot,
  required Directory cache,
}) async {
  final lock = readLock(packageRoot);
  String need(String key) =>
      lock[key] ?? (throw StateError('wxscan: $key missing from tflite.lock'));

  if (os == OS.android) {
    final abi = switch (architecture) {
      Architecture.arm64 => 'arm64-v8a',
      Architecture.arm => 'armeabi-v7a',
      Architecture.x64 => 'x86_64',
      // The LiteRT distribution has no 32-bit x86 build, which only affects
      // 32-bit emulators.
      _ => throw StateError('wxscan: no LiteRT build for $architecture'),
    };
    final version = need('LITERT_VERSION');
    final archive = await _download(
      'https://dl.google.com/dl/android/maven2/com/google/ai/edge/litert/litert/'
          '$version/litert-$version.aar',
      File.fromUri(cache.uri.resolve('litert-$version.aar')),
      need('LITERT_SHA256'),
    );
    final out = File.fromUri(cache.uri.resolve('android/$abi/libLiteRt.so'));
    _extractOne(archive, out, (name) => name == 'jni/$abi/libLiteRt.so');
    return TfliteLibrary(file: out, linkName: 'LiteRt', isStatic: false);
  }

  if (os == OS.iOS) {
    final version = need('IOS_VERSION');
    final archive = await _download(
      need('IOS_URL'),
      File.fromUri(cache.uri.resolve('TensorFlowLiteC-$version.tar.gz')),
      need('IOS_SHA256'),
    );
    // The xcframework holds one static framework per slice. The device and the
    // simulator are different slices of the same version.
    final slice = architecture == Architecture.arm64 && !_isSimulator
        ? 'ios-arm64'
        : 'ios-arm64_x86_64-simulator';
    // The framework binary is a single Mach-O object, not an archive, and
    // rustc will not take one as a static library; libtool wraps it into a
    // real one.
    final object = File.fromUri(cache.uri.resolve('ios/$slice/TensorFlowLiteC.o'));
    _extractOne(
      archive,
      object,
      (name) => name.endsWith(
        'TensorFlowLiteC.xcframework/$slice/TensorFlowLiteC.framework/TensorFlowLiteC',
      ),
    );
    final out = File.fromUri(cache.uri.resolve('ios/$slice/libTensorFlowLiteC.a'));
    if (!out.existsSync()) {
      final r = Process.runSync('libtool', ['-static', '-o', out.path, object.path]);
      if (r.exitCode != 0) {
        throw StateError('wxscan: libtool failed: ${r.stderr}');
      }
    }
    return TfliteLibrary(file: out, linkName: 'TensorFlowLiteC', isStatic: true);
  }

  // Desktop: one archive per OS and architecture, all holding a single shared
  // library under some directory the release happens to use.
  final version = need('DESKTOP_VERSION');
  final repo = need('DESKTOP_REPO');
  final (slug, ext, libName) = switch ((os, architecture)) {
    (OS.macOS, Architecture.arm64) =>
      ('darwin_arm64', 'tar.gz', 'libtensorflowlite_c.dylib'),
    // Was `(OS.macOS, _)`, which handed the arm64 library to an x86_64 target
    // and left the linker to say so — as a warning, in the middle of a
    // verbose log, followed by a hook failure that named nothing. A macOS
    // release build is universal unless told otherwise, so this is the shape
    // every release build took.
    (OS.macOS, _) => throw StateError(
        'wxscan: there is no x86_64 TFLite build for macOS — the desktop '
        'artifacts in tflite.lock are arm64 only, and no official desktop '
        'distribution exists to take one from.\n'
        'A macOS release build is universal by default, which is how a build '
        'that runs in debug reaches this. Set ARCHS to arm64 in '
        'macos/Runner/Configs/Release.xcconfig to build for Apple Silicon '
        'alone, which is the platform this package supports.'),
    (OS.linux, Architecture.x64) => ('linux_amd64', 'tar.gz', 'libtensorflowlite_c.so'),
    (OS.linux, Architecture.arm64) => ('linux_arm64', 'tar.gz', 'libtensorflowlite_c.so'),
    (OS.windows, _) => ('windows_amd64', 'zip', 'tensorflowlite_c.dll'),
    _ => throw StateError('wxscan: no TFLite build for $os/$architecture'),
  };
  final archiveName = 'tflite_c_${version}_$slug.$ext';
  final archive = await _download(
    'https://github.com/$repo/releases/download/$version/$archiveName',
    File.fromUri(cache.uri.resolve(archiveName)),
    need('SHA_$slug'),
  );
  final out = File.fromUri(cache.uri.resolve('$slug/$libName'));
  _extractOne(archive, out, _isSharedLibrary);

  if (os == OS.macOS) {
    // The archive carries a versioned install name, so it is rewritten for the
    // loader to find the library by the name it is linked against.
    final r = Process.runSync('install_name_tool', [
      '-id',
      '@rpath/libtensorflowlite_c.dylib',
      out.path,
    ]);
    if (r.exitCode != 0) {
      throw StateError('wxscan: install_name_tool failed: ${r.stderr}');
    }
  }
  return TfliteLibrary(file: out, linkName: 'tensorflowlite_c', isStatic: false);
}

/// Whether this is a simulator build. The hook input does not distinguish the
/// two, so the environment Xcode sets is what is left to go on.
bool get _isSimulator =>
    (Platform.environment['SDKROOT'] ?? '').contains('Simulator') ||
    Platform.environment['PLATFORM_NAME'] == 'iphonesimulator';

bool _isSharedLibrary(String name) {
  final base = name.split('/').last;
  // These archives carry AppleDouble resource forks and PAX headers beside the
  // real entries, and both can end in the extension being looked for.
  if (base.startsWith('._') || name.contains('PaxHeader')) return false;
  return base.endsWith('.dylib') ||
      base.endsWith('.dll') ||
      base.endsWith('.so') ||
      base.contains('.so.');
}

/// Downloads [url] to [out] unless it is already there with the right digest.
Future<File> _download(String url, File out, String wantSha256) async {
  if (out.existsSync() && _sha256(out) == wantSha256) return out;
  out.parent.createSync(recursive: true);

  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw StateError('wxscan: GET $url returned ${response.statusCode}');
    }
    final part = File('${out.path}.part');
    await response.pipe(part.openWrite());
    final got = _sha256(part);
    if (got != wantSha256) {
      part.deleteSync();
      throw StateError(
        'wxscan: checksum mismatch for $url\n'
        '  expected $wantSha256\n'
        '  got      $got',
      );
    }
    part.renameSync(out.path);
  } finally {
    client.close();
  }
  return out;
}

String _sha256(File f) => sha256.convert(f.readAsBytesSync()).toString();

/// Extracts the first entry [matches] accepts from [archive] to [out].
void _extractOne(File archive, File out, bool Function(String name) matches) {
  if (out.existsSync()) return;
  final bytes = archive.readAsBytesSync();
  final isZip = archive.path.endsWith('.zip') || archive.path.endsWith('.aar');
  final found = isZip
      ? _findInZip(bytes, matches)
      : _findInTar(Uint8List.fromList(gzip.decode(bytes)), matches);
  if (found == null) {
    throw StateError('wxscan: nothing matched inside ${archive.path}');
  }
  out.parent.createSync(recursive: true);
  out.writeAsBytesSync(found);
}

Uint8List? _findInZip(List<int> bytes, bool Function(String name) matches) {
  for (final entry in ZipDecoder().decodeBytes(bytes).files) {
    if (entry.isFile && matches(entry.name)) return entry.readBytes();
  }
  return null;
}

/// Reads a tar far enough to pull one member out of it.
///
/// `package:archive`'s tar reader rejects the archives these releases ship, and
/// only one file is ever wanted, so the format is walked directly: 512-byte
/// header blocks, the name in the first 100 bytes, the size as octal at 124,
/// and the contents following, padded to the next block.
Uint8List? _findInTar(Uint8List bytes, bool Function(String name) matches) {
  var offset = 0;
  while (offset + 512 <= bytes.length) {
    final header = bytes.sublist(offset, offset + 512);
    // Two zero blocks end the archive; one is enough to stop here.
    if (header.every((b) => b == 0)) break;
    final name = _cString(header, 0, 100);
    final size = _octal(header, 124, 12);
    final type = header[156];
    offset += 512;
    // Type '0' and the historical NUL both mean a regular file.
    if ((type == 0x30 || type == 0) && matches(name)) {
      return bytes.sublist(offset, offset + size);
    }
    offset += (size + 511) & ~511;
  }
  return null;
}

String _cString(Uint8List b, int start, int length) {
  var end = start;
  while (end < start + length && b[end] != 0) {
    end++;
  }
  return String.fromCharCodes(b, start, end);
}

int _octal(Uint8List b, int start, int length) {
  final text = _cString(b, start, length).trim();
  return text.isEmpty ? 0 : int.parse(text, radix: 8);
}
