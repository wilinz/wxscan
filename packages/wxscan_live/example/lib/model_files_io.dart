import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:large_file_handler/large_file_handler.dart';
import 'package:path_provider/path_provider.dart';

/// Where the copy goes, under the documents directory.
///
/// Relative, because that is what `copyAssetToLocalStorage` takes: it resolves
/// a name against `getApplicationDocumentsDirectory` on every platform, in its
/// Dart layer, before the native side sees an absolute path. The same
/// directory is reconstructed below to hand the scanner a path of its own —
/// the plugin copies but does not say where to.
const _dirName = 'wxscan-models';

/// Copies the bundled weights into the sandbox when what is there is not what
/// is bundled, and returns the two paths.
///
/// The copying is `large_file_handler`, which streams: on Android the asset
/// goes from `AssetManager.open` into a `FileOutputStream`, on Apple from the
/// file it already is inside the bundle through `InputStream` and
/// `OutputStream`. Neither passes the megabyte through Dart at all. If it
/// fails anyway the asset is read here and written in chunks, which is what
/// this did everywhere before the plugin.
///
/// [readAsset] is used only for the few dozen bytes of the manifest, and is
/// passed in rather than imported so that this file knows nothing about the
/// bundle beyond that.
///
/// **The copy has to be made again when the weights change**, or an update
/// that ships new ones goes on decoding with the old and nothing says so.
/// `assets/models/model-version.txt` is what decides that:
///
/// ```
/// version 1
/// detect.tflite 1024676
/// sr.tflite 71576
/// ```
///
/// A copy whose size does not match is replaced. That costs one tiny asset and
/// one `stat` per run, where comparing contents would mean reading the
/// megabyte on every start to discover it was not needed. It also catches the
/// other way a copy goes wrong: a write interrupted by a kill or a full disk
/// leaves a file that exists, is short, and would otherwise be opened by every
/// run from then on.
Future<(String detect, String sr)> installWeights(
  Future<Uint8List> Function(String assetKey) readAsset,
) async {
  final want = _manifest(
    String.fromCharCodes(await readAsset('assets/models/model-version.txt')),
  );
  final dir = Directory(
    '${(await getApplicationDocumentsDirectory()).path}/$_dirName',
  );
  // The plugin writes with a plain file stream and does not create parents.
  await dir.create(recursive: true);

  Future<bool> isCurrent(File file, int? expected) async =>
      expected != null &&
      await file.exists() &&
      await file.length() == expected;

  Future<String> install(String name) async {
    final file = File('${dir.path}/$name');
    final expected = want[name];
    if (await isCurrent(file, expected)) return file.path;

    try {
      await LargeFileHandler().copyAssetToLocalStorage(
        assetName: 'models/$name',
        targetPath: '$_dirName/$name',
      );
      // Checked rather than trusted: a copy that ended early leaves a file
      // that exists, and the whole point of the manifest is not to open one.
      if (await isCurrent(file, expected)) return file.path;
      if (expected == null && await file.exists()) return file.path;
      _log('$name: the plugin reported success and the file is not right');
    } on Object catch (e) {
      // No platform is expected to take this branch. macOS did until
      // large_file_handler 0.5.1: it looked the asset up with
      // `Bundle.main.path(forResource:)`, which only searches Resources, while
      // the key the engine returns there is a path from the bundle root into
      // App.framework — so every copy came back "Asset not found 404"
      // (DenisovAV/large_file_handler#10). Kept as a fallback rather than
      // deleted with the fix, because the asset is readable from here whatever
      // the plugin's reason, and the alternative to falling back is a demo
      // that cannot scan.
      _log('$name: the plugin could not copy it ($e), reading it here instead');
    }

    // The way this worked before the plugin, and the way it still works when
    // the plugin will not: the asset arrives as one buffer — no public Flutter
    // API streams one — and goes out in chunks.
    final bytes = await readAsset('assets/models/$name');
    final tmp = File('${file.path}.part');
    await _writeStreaming(tmp, bytes);
    await tmp.rename(file.path);
    return file.path;
  }

  return (await install('detect.tflite'), await install('sr.tflite'));
}

/// Writes [bytes] a chunk at a time, awaiting each one.
///
/// `writeAsBytes` hands the whole buffer to the sink and lets it queue, so the
/// file and the queue are both the size of the model for as long as the write
/// takes. Awaiting `flush` per chunk bounds the write side to 64 KB instead,
/// and the sublists are views rather than copies.
Future<void> _writeStreaming(File file, Uint8List bytes) async {
  const chunk = 64 * 1024;
  final sink = file.openWrite();
  try {
    for (var i = 0; i < bytes.length; i += chunk) {
      final end = i + chunk < bytes.length ? i + chunk : bytes.length;
      sink.add(Uint8List.sublistView(bytes, i, end));
      // Not decoration: without it the sink queues every chunk and the saving
      // is undone.
      await sink.flush();
    }
  } finally {
    await sink.close();
  }
}

void _log(String message) {
  developer.log('weights: $message', name: 'wxscan');
  // Printed as well, as Scanner does: falling back to reading the asset here
  // is the kind of thing that should be visible in `flutter run` rather than
  // only to someone who thought to attach the VM service.
  // ignore: avoid_print
  print('[wxscan] weights: $message');
}

/// `name bytes` per line, `#` for a comment. Anything unparseable is left out,
/// which means that file is copied again — the safe way to be wrong.
Map<String, int> _manifest(String text) {
  final out = <String, int>{};
  for (final line in text.split('\n')) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length != 2) continue;
    final n = int.tryParse(parts[1]);
    if (n != null) out[parts[0]] = n;
  }
  return out;
}
