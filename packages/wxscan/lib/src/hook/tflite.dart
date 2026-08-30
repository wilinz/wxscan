/// Fetching the prebuilt TFLite C library.
///
/// The library is not kept in the repository: it is megabytes per platform.
/// Everything is fetched from one release — one repository, one tag, nine
/// archives — built from one TensorFlow version by one script, so Android,
/// iOS and the desktops link the same runtime, and each archive is pinned by
/// SHA-256 in `tool/tflite.lock`; a mismatch fails the build.
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
  final String linkName;

  /// iOS builds a static archive, which is linked into the Rust library
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

  // One table, one archive per row. The archive holds the library under a
  // name the release decides, next to a `.build` file, and the exact name is
  // what is matched inside.
  final version = need('TFLITE_VERSION');
  final repo = need('TFLITE_REPO');
  final (slug, ext, libName, isStatic) = switch ((os, architecture)) {
    (OS.android, Architecture.arm64) =>
      ('android_arm64', 'tar.gz', 'libtensorflowlite_c.so', false),
    (OS.android, Architecture.arm) =>
      ('android_arm', 'tar.gz', 'libtensorflowlite_c.so', false),
    (OS.android, Architecture.x64) =>
      ('android_x64', 'tar.gz', 'libtensorflowlite_c.so', false),
    // Static, because that is how an iOS application takes a C library: there
    // is no rpath to load a .dylib from. The simulator archive holds both
    // slices in one archive, which a linker reads as the one slice of its own.
    (OS.iOS, _) when !_isSimulator && architecture == Architecture.arm64 =>
      ('ios_device', 'tar.gz', 'libtensorflowlite_c.a', true),
    (OS.iOS, _) when _isSimulator =>
      ('ios_simulator', 'tar.gz', 'libtensorflowlite_c.a', true),
    // One archive holds both macOS slices; it is thinned below to whichever
    // one this call is for. Architectures are named rather than matched with
    // `_` so that anything else — a macOS target Apple has not shipped —
    // falls through to the error at the end instead of being handed a
    // library that cannot hold it.
    (OS.macOS, Architecture.arm64 || Architecture.x64) =>
      ('darwin_universal', 'tar.gz', 'libtensorflowlite_c.dylib', false),
    (OS.linux, Architecture.x64) =>
      ('linux_amd64', 'tar.gz', 'libtensorflowlite_c.so', false),
    (OS.linux, Architecture.arm64) =>
      ('linux_arm64', 'tar.gz', 'libtensorflowlite_c.so', false),
    (OS.windows, _) => ('windows_amd64', 'zip', 'tensorflowlite_c.dll', false),
    _ => throw StateError('wxscan: no TFLite build for $os/$architecture'),
  };
  final archiveName = 'tflite_c_${version}_$slug.$ext';
  final archive = await _download(
    'https://github.com/$repo/releases/download/$version/$archiveName',
    File.fromUri(cache.uri.resolve(archiveName)),
    need('SHA_$slug'),
  );
  var out = File.fromUri(cache.uri.resolve('$slug/$libName'));
  _extractOne(archive, out, (name) => name.split('/').last == libName);

  // MSVC links against the import library rather than the DLL, and stops at
  // LNK1181 without ever opening the DLL if it is missing. Nothing loads this
  // file at run time and it is not a code asset; it only has to be in the
  // directory build.rs hands to the linker, which is this one.
  if (os == OS.windows) {
    const importLib = 'tensorflowlite_c.lib';
    _extractOne(
      archive,
      File.fromUri(cache.uri.resolve('$slug/$importLib')),
      (name) => name.split('/').last == importLib,
    );
  }

  // The macOS archive is universal; each build gets the slice it asked for.
  // Its install name is already @rpath/libtensorflowlite_c.dylib, which the
  // Dart tooling reads to rewrite the dependency path.
  if (os == OS.macOS) {
    out = _thin(out, architecture, cache.uri.resolve('$slug/'), libName);
  }
  return TfliteLibrary(
    file: out,
    linkName: 'tensorflowlite_c',
    isStatic: isStatic,
  );
}

/// Whether this is a simulator build. The hook input does not distinguish the
/// two, so the environment Xcode sets is what is left to go on.
bool get _isSimulator =>
    (Platform.environment['SDKROOT'] ?? '').contains('Simulator') ||
    Platform.environment['PLATFORM_NAME'] == 'iphonesimulator';

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
/// Cuts one architecture out of a macOS library that holds several.
///
/// A hook is called once per target architecture, and the Dart tooling that
/// bundles what it returns cannot read a universal one: `dart test` stops at
/// `Expected a single architecture section in otool output`, because it takes
/// the install name from `otool -D`, which prints a section per architecture.
/// So a universal library is thinned here and each build gets the slice it
/// asked for. Sliced beside the whole file rather than over it, since the
/// other architecture's build reads the same cache.
///
/// A library that already holds one architecture is returned untouched, so
/// this costs nothing where the release is not universal.
File _thin(File fat, Architecture architecture, Uri dir, String libName) {
  final arch = switch (architecture) {
    Architecture.arm64 => 'arm64',
    Architecture.x64 => 'x86_64',
    _ => throw StateError('wxscan: no macOS TFLite build for $architecture'),
  };

  final archs = Process.runSync('lipo', ['-archs', fat.path]);
  if (archs.exitCode != 0) {
    throw StateError('wxscan: lipo -archs failed: ${archs.stderr}');
  }
  final held = (archs.stdout as String).trim().split(RegExp(r'\s+'));
  if (held.length == 1) {
    if (held.single != arch) {
      throw StateError('wxscan: ${fat.path} is $held, not $arch');
    }
    return fat;
  }
  if (!held.contains(arch)) {
    throw StateError('wxscan: ${fat.path} holds $held, which does not include '
        '$arch');
  }

  final out = File.fromUri(dir.resolve('$arch/$libName'));
  if (out.existsSync()) return out;
  out.parent.createSync(recursive: true);
  // Written beside and moved into place: two architectures build at once, and
  // an interrupted lipo must not leave a truncated library under a name that
  // says it is finished.
  final part = File('${out.path}.part');
  final r = Process.runSync('lipo', ['-thin', arch, fat.path, '-output', part.path]);
  if (r.exitCode != 0) {
    throw StateError('wxscan: lipo -thin $arch failed: ${r.stderr}');
  }
  part.renameSync(out.path);
  return out;
}

void _extractOne(File archive, File out, bool Function(String name) matches) {
  if (out.existsSync()) return;
  final bytes = archive.readAsBytesSync();
  final isZip = archive.path.endsWith('.zip');
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
