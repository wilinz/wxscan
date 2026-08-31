import 'dart:io';

import 'package:path/path.dart' as p;

/// Annotated `v<version>` tags, one per repository.
///
/// Tagging was the one release step nothing drove. The documentation said to
/// do it, four repositories out of four were tagged for a while, and then
/// 0.1.4 and 0.1.5 went out untagged and nobody noticed until someone went
/// looking for the commit a published version came from. That is the same
/// shape as the path-dependency release: a step that lives only in someone's
/// memory is a step that is eventually skipped.
///
/// Tags are created locally and never pushed. Pushing is what makes a tag
/// visible to everyone and is the one part of this that cannot be quietly
/// undone, so it stays a decision rather than a side effect; [pushCommand]
/// prints what to run.
class Tags {
  Tags({required this.dryRun});

  final bool dryRun;

  /// Whether `v[version]` already exists in [repoRoot].
  Future<bool> exists(String repoRoot, String version) async {
    final result = await _git(repoRoot, [
      'rev-parse',
      '--verify',
      '--quiet',
      'refs/tags/${tagName(version)}',
    ]);
    return result.exitCode == 0;
  }

  /// Creates an annotated `v[version]` tag on HEAD of [repoRoot].
  ///
  /// Returns what happened, so a caller can report a repository that was
  /// already tagged differently from one it just tagged.
  ///
  /// [label] names the thing in the tag's subject line — the repository
  /// directory, which is also what the existing tags use.
  Future<TagResult> create(
    String repoRoot, {
    required String version,
    required String label,
    String? body,
    bool allowDirty = false,
  }) async {
    final name = tagName(version);

    if (await exists(repoRoot, version)) {
      final at = await _describe(repoRoot, 'refs/tags/$name^{commit}');
      return TagResult.already(name, at);
    }

    final head = await _git(repoRoot, ['rev-parse', '--verify', 'HEAD']);
    if (head.exitCode != 0) {
      throw StateError(
        '${p.basename(repoRoot)} has no commits, so there is nothing to tag '
        'as $name.',
      );
    }

    // HEAD is what gets tagged, so uncommitted work is not in the tag however
    // much it looks like part of this release. Worth stopping for: a tag
    // pointing at a tree that is not what was published is worse than no tag,
    // because it is believed.
    if (!allowDirty) {
      final status = await _git(repoRoot, ['status', '--porcelain']);
      final dirty = status.stdout.toString().trim();
      if (dirty.isNotEmpty) {
        final count = dirty.split('\n').length;
        throw StateError(
          'Refusing to tag ${p.basename(repoRoot)} as $name: $count '
          'uncommitted path${count == 1 ? '' : 's'}.\n'
          'A tag points at HEAD, so those changes would not be in it.\n'
          'Commit them, or pass --allow-dirty to tag HEAD as it stands.',
        );
      }
    }

    final notes = body?.trim();
    final message = [
      '$label $version',
      if (notes != null && notes.isNotEmpty) ...['', notes],
    ].join('\n');

    if (dryRun) {
      return TagResult.created(name, await _describe(repoRoot, 'HEAD'));
    }

    // Through a file rather than -m: the message carries blank lines and
    // whatever punctuation the changelog uses, and an argument list is the
    // wrong place for either.
    final file = File(
      p.join(Directory.systemTemp.path, 'publish-kit-tag-$name.txt'),
    );
    await file.writeAsString('$message\n');
    try {
      final result = await _git(repoRoot, ['tag', '-a', name, '-F', file.path]);
      if (result.exitCode != 0) {
        throw StateError(
          'git tag failed in ${p.basename(repoRoot)}: '
          '${result.stderr.toString().trim()}',
        );
      }
    } finally {
      if (file.existsSync()) await file.delete();
    }

    return TagResult.created(name, await _describe(repoRoot, 'HEAD'));
  }

  /// The `## <version>` section of a changelog, or null when there is none.
  ///
  /// Best-effort by design: a missing changelog or a version with no entry
  /// yet is not a reason to refuse to tag, it just means the tag carries only
  /// its subject line.
  static String? changelogSection(String path, String version) {
    final file = File(path);
    if (!file.existsSync()) return null;

    final lines = file.readAsLinesSync();
    final heading = RegExp('^##\\s+v?${RegExp.escape(version)}\\s*\$');
    final start = lines.indexWhere(heading.hasMatch);
    if (start < 0) return null;

    final rest = lines.skip(start + 1);
    final section = <String>[];
    for (final line in rest) {
      if (line.startsWith('## ')) break;
      section.add(line);
    }
    final text = section.join('\n').trim();
    return text.isEmpty ? null : text;
  }

  static String tagName(String version) => 'v$version';

  /// How to push one tag.
  ///
  /// Per repository, and not a single line: these are four separate
  /// repositories that happen to share a parent directory, so there is no one
  /// `git push` that reaches all of them. A combined line looks like it works
  /// and pushes one repository's tag four times.
  static String pushCommand(String repoDirName, String tagName) =>
      'cd $repoDirName && git push origin $tagName';

  Future<String> _describe(String repoRoot, String rev) async {
    final result = await _git(repoRoot, ['log', '-1', '--format=%h %s', rev]);
    return result.exitCode == 0
        ? result.stdout.toString().trim()
        : '(unknown commit)';
  }

  Future<ProcessResult> _git(String repoRoot, List<String> arguments) =>
      Process.run('git', arguments, workingDirectory: repoRoot);
}

/// What [Tags.create] did.
class TagResult {
  const TagResult.created(this.name, this.commit) : wasCreated = true;
  const TagResult.already(this.name, this.commit) : wasCreated = false;

  final String name;

  /// Short hash and subject of the commit the tag points at.
  final String commit;

  /// False when the tag was already there, which is the normal state of a
  /// repository that did not move this release.
  final bool wasCreated;
}
