import 'dart:io';

import 'package:yaml_edit/yaml_edit.dart';

/// Reading and rewriting the version and dependency fields the release touches.
///
/// Every edit here is deliberately narrow. These files carry comments that
/// explain non-obvious decisions, and a rewrite that reformats them loses that,
/// so nothing rewrites a whole manifest — each function replaces exactly the
/// field it names and fails loudly if that field is not where it expects.
class Manifests {
  Manifests({required this.dryRun});

  final bool dryRun;

  Future<void> _write(File file, String contents, String what) async {
    if (!dryRun) {
      await file.writeAsString(contents);
    }
    print('${dryRun ? "[dry-run] " : ""}$what');
  }

  /// Reads `version.txt` from a repository root.
  ///
  /// One file per repository, not one for both: the Rust crates and the Flutter
  /// plugin are separate release trains, and forcing them to share a number
  /// would mean bumping six crates because a Dart-only fix shipped.
  Future<String> readVersion(String repoRoot) async {
    final file = File('$repoRoot/version.txt');
    if (!file.existsSync()) {
      throw StateError(
        'No version.txt in $repoRoot. Create it holding just the version, '
        'e.g. "0.1.0".',
      );
    }
    final version = (await file.readAsString()).trim();
    if (version.isEmpty) {
      throw StateError('$repoRoot/version.txt is empty.');
    }
    return version;
  }

  /// Sets `[workspace.package] version` in the Rust workspace manifest.
  ///
  /// All six crates inherit through `version.workspace = true`, so this single
  /// edit moves the whole workspace.
  Future<void> setRustWorkspaceVersion(String repoRoot, String version) async {
    final file = File('$repoRoot/Cargo.toml');
    final contents = await file.readAsString();

    final section = RegExp(
      r'(\[workspace\.package\]\n(?:(?!\s*\[)[^\n]*\n)*?version\s*=\s*)"[^"]*"',
    );
    if (!section.hasMatch(contents)) {
      throw StateError(
        'Could not find a version under [workspace.package] in '
        '$repoRoot/Cargo.toml.',
      );
    }

    await _write(
      file,
      contents.replaceFirstMapped(section, (m) => '${m[1]}"$version"'),
      'Cargo.toml: workspace version -> $version',
    );
  }

  /// Sets `version` under `[package]` in a standalone crate manifest.
  ///
  /// cvlite and wxing each own their repository now, so neither inherits from a
  /// `[workspace.package]` block any more.
  Future<void> setCargoPackageVersion(
    String manifestPath,
    String version,
  ) async {
    final file = File(manifestPath);
    final contents = await file.readAsString();

    // Lines rather than characters: the table was previously bounded by
    // "anything that is not a `[`", which a manifest carrying `keywords` or
    // `categories` above its version breaks — those values are arrays, and
    // the crate then reports no version at all. A table ends at the next line
    // opening one, so that is what the search stops at.
    final section = RegExp(
      r'(\[package\]\n(?:(?!\s*\[)[^\n]*\n)*?version\s*=\s*)"[^"]*"',
    );
    if (!section.hasMatch(contents)) {
      throw StateError('No version under [package] in $manifestPath.');
    }

    await _write(
      file,
      contents.replaceFirstMapped(section, (m) => '${m[1]}"$version"'),
      '${_short(manifestPath)}: package version -> $version',
    );
  }

  /// Adds or removes a `[patch.crates-io]` block at the end of a manifest.
  ///
  /// Passing null removes it. The block is what lets a manifest declare its
  /// siblings by version — the only publishable form — while still building
  /// against local checkouts, so it exists in development and must be gone
  /// before publishing.
  Future<void> setCargoPatch(
    String manifestPath,
    Map<String, String>? entries, {
    String? comment,
  }) async {
    final file = File(manifestPath);
    var contents = await file.readAsString();

    // Strip any existing block, together with the comment lines directly above
    // it, so repeated runs do not stack up copies.
    final existing = RegExp(
      r'\n*(?:^#[^\n]*\n)*^\[patch\.crates-io\]\n(?:^[^\[\n][^\n]*\n?)*',
      multiLine: true,
    );
    contents = contents.replaceAll(existing, '\n');

    if (entries != null) {
      final buffer = StringBuffer('\n');
      if (comment != null) {
        for (final line in comment.trimRight().split('\n')) {
          buffer.writeln(line.isEmpty ? '#' : '# $line');
        }
      }
      buffer.writeln('[patch.crates-io]');
      entries.forEach((name, spec) => buffer.writeln('$name = $spec'));
      contents = '${contents.trimRight()}\n$buffer';
    }

    await _write(
      file,
      contents,
      '${_short(manifestPath)}: '
      '${entries == null ? "removed" : "wrote"} [patch.crates-io]',
    );
  }

  /// Sets `version:` in a pubspec.
  Future<void> setPubspecVersion(String packageDir, String version) async {
    final file = File('$packageDir/pubspec.yaml');
    final editor = YamlEditor(await file.readAsString());
    editor.update(['version'], version);
    await _write(file, editor.toString(), '$packageDir: version -> $version');
  }

  /// Points `wxscan_live`'s constraint on `wxscan` at [version].
  Future<void> setPubDependency(
    String packageDir,
    String dependency,
    String constraint,
  ) async {
    final file = File('$packageDir/pubspec.yaml');
    final editor = YamlEditor(await file.readAsString());
    editor.update(['dependencies', dependency], constraint);
    await _write(
      file,
      editor.toString(),
      '$packageDir: $dependency -> $constraint',
    );
  }

  /// Replaces one dependency line in a Cargo manifest.
  ///
  /// This is the edit the whole release hinges on. `wxscan/rust` depends
  /// on `wxscan-ffi` and `wxscan` by a path into a sibling `wxscan-rs`
  /// checkout, which nobody installing from pub.dev has; leaving it that way
  /// ships a package whose build hook cannot build. Switching it to a version
  /// is what makes the package installable, and switching it back is what keeps
  /// local development working against uncommitted Rust changes.
  ///
  /// Throws unless the key appears exactly once, so a manifest that drifted
  /// from what this expects stops the release instead of being half-edited.
  Future<void> setCargoDependency(
    String manifestPath,
    String dependency,
    String spec,
  ) async {
    final file = File(manifestPath);
    final lines = (await file.readAsString()).split('\n');

    final key = RegExp('^${RegExp.escape(dependency)}\\s*=');
    final matches = <int>[
      for (var i = 0; i < lines.length; i++)
        if (key.hasMatch(lines[i])) i,
    ];

    if (matches.length != 1) {
      throw StateError(
        'Expected exactly one "$dependency = ..." line in $manifestPath, '
        'found ${matches.length}. Fix the manifest by hand and re-run.',
      );
    }

    lines[matches.single] = '$dependency = $spec';
    await _write(
      file,
      lines.join('\n'),
      '${_short(manifestPath)}: $dependency = $spec',
    );
  }

  /// Reads back one dependency line, for the preflight report.
  Future<String?> readCargoDependency(
    String manifestPath,
    String dependency,
  ) async {
    final file = File(manifestPath);
    if (!file.existsSync()) return null;

    final key = RegExp('^${RegExp.escape(dependency)}\\s*=');
    for (final line in (await file.readAsString()).split('\n')) {
      if (key.hasMatch(line)) return line.trim();
    }
    return null;
  }

  static String _short(String path) {
    final parts = path.split('/');
    return parts.length <= 3 ? path : '.../${parts.sublist(parts.length - 3).join('/')}';
  }
}
