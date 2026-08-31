import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:publish_kit/publish_kit.dart';

const _commands = {
  'check': 'Report anything that would block a release. Changes nothing.',
  'update-version': 'Propagate each version.txt into its manifests.',
  'release-deps': 'Point wxscan/rust at crates.io instead of the sibling checkout.',
  'restore-dev': 'Point wxscan/rust back at the sibling checkout.',
  'publish': 'Publish everything not already up, in dependency order.',
  'tag': 'Tag each repository at its current version. Pushes nothing.',
};

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag(
      'dry-run',
      abbr: 'd',
      help: 'Print and pack, but upload nothing and edit no file.',
    )
    ..addFlag(
      'allow-dirty',
      help: 'Pass --allow-dirty to cargo. Required until wxscan-rs is committed.',
    )
    ..addMultiOption(
      'only',
      help: 'Limit publishing to these targets, e.g. --only crate:cvlite.',
    )
    ..addOption(
      'workspace-root',
      help: 'Directory holding all four checkouts. Defaults to searching upward.',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

  late final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    _usage(parser);
    exit(64);
  }

  if (args['help'] as bool || args.rest.isEmpty) {
    _usage(parser);
    exit(args['help'] as bool ? 0 : 64);
  }

  final command = args.rest.first;
  if (!_commands.containsKey(command)) {
    stderr.writeln('Unknown command "$command".');
    _usage(parser);
    exit(64);
  }

  // `dart run publish_kit` executes a snapshot under .dart_tool, so
  // Platform.script does not locate anything. Walk up from the working
  // directory instead, looking for the layout this kit drives.
  final workspaceRoot =
      (args['workspace-root'] as String?) ?? _findWorkspaceRoot();
  if (workspaceRoot == null) {
    stderr.writeln(
      'Could not find the four checkouts side by side above '
      '${Directory.current.path}. Pass --workspace-root.',
    );
    exit(66);
  }
  final kit = PublishKit(
    workspaceRoot: workspaceRoot,
    dryRun: args['dry-run'] as bool,
    allowDirty: args['allow-dirty'] as bool,
  );

  try {
    switch (command) {
      case 'check':
        if (!await kit.check()) exit(1);
      case 'update-version':
        await kit.updateVersions();
      case 'release-deps':
        await kit.releaseDeps();
      case 'restore-dev':
        await kit.restoreDev();
      case 'publish':
        final only = (args['only'] as List<String>).toSet();
        await kit.publish(only: only.isEmpty ? null : only);
      case 'tag':
        if (!await kit.tagRelease()) exit(1);
    }
  } on StateError catch (e) {
    stderr.writeln('\nError: ${e.message}');
    exit(1);
  } finally {
    kit.close();
  }
}

/// Walks up from the working directory to the parent holding all checkouts.
///
/// The marker is every repository in [Repo] being present as a sibling, so
/// running this from inside any one of them finds the same root.
String? _findWorkspaceRoot() {
  var dir = Directory.current.absolute.path;
  while (true) {
    final complete = Repo.values.every(
      (repo) => Directory(p.join(dir, repo.dirName)).existsSync(),
    );
    if (complete) return dir;
    final parent = p.dirname(dir);
    if (parent == dir) return null;
    dir = parent;
  }
}

void _usage(ArgParser parser) {
  stdout.writeln('wxscan release driver\n');
  stdout.writeln('Usage: dart run publish_kit <command> [options]\n');
  stdout.writeln('Commands:');
  for (final entry in _commands.entries) {
    stdout.writeln('  ${entry.key.padRight(16)}${entry.value}');
  }
  stdout.writeln('\nOptions:');
  stdout.writeln(parser.usage);
  stdout.writeln('\nRepositories:');
  for (final repo in Repo.values) {
    stdout.writeln('  ${repo.dirName.padRight(12)}${repo.summary}');
  }
  stdout.writeln('\nRelease order:');
  for (final target in releasePlan) {
    stdout.writeln('  ${target.id}');
  }
  stdout.writeln(
    '\nThere is deliberately no "all". The chain crosses two registries and '
    'cannot be\nundone once a version is up; each step is run on purpose.\n'
    '\n`publish` tags what it released. `tag` on its own is for a release that\n'
    'went out untagged. Neither pushes anything.',
  );
}
