import 'dart:io';

import 'package:path/path.dart' as p;

import 'src/manifests.dart';
import 'src/plan.dart';
import 'src/registry_client.dart';

export 'src/plan.dart';

/// Drives the wxscan release across four repositories and two registries.
///
/// Ported from wilinz/froom's publish-kit. What carried over is the shape:
/// ordered publishing, waiting for the registry to catch up between steps, and
/// skipping what is already up so an interrupted run can simply be re-run.
/// Everything multi-repository and everything cargo is new.
class PublishKit {
  PublishKit({
    required this.workspaceRoot,
    this.dryRun = false,
    this.allowDirty = false,
  }) : _manifests = Manifests(dryRun: dryRun);

  /// The directory holding all four checkouts side by side.
  final String workspaceRoot;

  final bool dryRun;

  /// Passes `--allow-dirty` to cargo. Needed while a repository has
  /// uncommitted or untracked files.
  final bool allowDirty;

  final Manifests _manifests;
  final RegistryClient _registry = RegistryClient();

  String rootOf(Repo repo) => p.join(workspaceRoot, repo.dirName);

  String dirOf(Target target) => p.join(rootOf(target.repo), target.dir);

  Future<String> versionOf(Target target) =>
      _manifests.readVersion(rootOf(target.repo));

  /// The Rust crate inside the Dart package — the one manifest that names
  /// every other repository, and the reason the release order is what it is.
  String get _coreRustManifest =>
      p.join(rootOf(Repo.dart), 'packages/wxscan/rust/Cargo.toml');

  /// Relative path from [_coreRustManifest] up to the shared parent.
  String get _coreToWorkspace =>
      p.relative(workspaceRoot, from: p.dirname(_coreRustManifest));

  // ---- preflight ---------------------------------------------------------

  /// Reports everything that would stop a release, without changing anything.
  Future<bool> check() async {
    var ok = true;

    void fail(String message) {
      ok = false;
      print('  FAIL  $message');
    }

    void pass(String message) => print('  ok    $message');

    print('Release plan');
    final planIssues = planProblems();
    if (planIssues.isEmpty) {
      pass('${releasePlan.length} targets, each after what it depends on');
    } else {
      for (final issue in planIssues) {
        fail(issue);
      }
    }

    print('\nRepositories (under $workspaceRoot)');
    final versions = <Repo, String>{};
    for (final repo in Repo.values) {
      final root = rootOf(repo);
      if (!Directory(root).existsSync()) {
        fail('${repo.dirName} is missing — expected at $root');
        continue;
      }
      try {
        final version = await _manifests.readVersion(root);
        versions[repo] = version;
        pass('${repo.dirName.padRight(10)} $version — ${repo.summary}');
      } on StateError catch (e) {
        fail(e.message);
      }
    }

    print('\nCross-repository wiring');
    for (final dep in ['wxscan-ffi', 'wxscan']) {
      final line = await _manifests.readCargoDependency(_coreRustManifest, dep);
      if (line == null) {
        fail('$dep not found in wxscan/rust/Cargo.toml');
      } else if (line.contains('path')) {
        print(
          '  note  $dep is on a path dependency — development mode.\n'
          '        Run `release-deps` before publishing wxscan.',
        );
      } else {
        pass('$dep is on a version dependency: $line');
      }
    }
    // At the start of a line, because the header comment above the
    // dependencies explains what the block is for and names it — a substring
    // search reads that explanation as the block itself and reports
    // development mode to anyone who has just left it.
    final hasPatch = RegExp(r'^\[patch\.crates-io\]', multiLine: true)
        .hasMatch(File(_coreRustManifest).readAsStringSync());
    if (hasPatch) {
      print(
        '  note  wxscan/rust carries a [patch.crates-io] block —\n'
        '        development mode. `release-deps` removes it.',
      );
    }

    print('\nRegistry status');
    for (final target in releasePlan) {
      final version = versions[target.repo];
      if (version == null) continue;

      final published = await _registry.isPublished(target, version);
      switch (published) {
        case true:
          print('  ---   ${target.id} $version already published, will skip');
        case false:
          pass('${target.id} $version is free');
        case null:
          fail('${target.id}: could not reach ${target.registry.host}');
      }
    }

    print('\nGit');
    for (final repo in Repo.values) {
      final root = rootOf(repo);
      if (!Directory(root).existsSync()) continue;

      // Three distinct states, which an exit code alone conflates: not a
      // repository, a repository with no commits, and a repository with a
      // history. Only the first needs `git init`.
      final toplevel = await Process.run('git', [
        'rev-parse',
        '--show-toplevel',
      ], workingDirectory: root);
      if (toplevel.exitCode != 0 ||
          p.equals(toplevel.stdout.toString().trim(), root) == false) {
        fail(
          '${repo.dirName} is not its own git repository.\n'
          '        Run `git init` there: each repository advertises its own\n'
          '        URL in `repository`, and that URL has to exist.',
        );
        continue;
      }

      final head = await Process.run('git', [
        'rev-parse',
        '--verify',
        'HEAD',
      ], workingDirectory: root);
      if (head.exitCode != 0) {
        print('  note  ${repo.dirName} has no commits yet — pass --allow-dirty');
        continue;
      }

      final status = await Process.run('git', [
        'status',
        '--porcelain',
      ], workingDirectory: root);
      final dirty = status.stdout.toString().trim();
      if (dirty.isEmpty) {
        pass('${repo.dirName} is clean');
      } else {
        print(
          '  note  ${repo.dirName} has ${dirty.split('\n').length} '
          'uncommitted paths',
        );
      }
    }

    print('\n${ok ? "Preflight passed." : "Preflight found blockers."}');
    return ok;
  }

  // ---- version ------------------------------------------------------------

  /// Propagates each repository's `version.txt` into its manifests, and into
  /// every constraint the other repositories place on it.
  ///
  /// Four version files rather than one: the split exists so these can move
  /// independently, and a shared number would put that straight back.
  Future<void> updateVersions() async {
    final v = <Repo, String>{
      for (final repo in Repo.values)
        repo: await _manifests.readVersion(rootOf(repo)),
    };
    v.forEach((repo, version) => print('${repo.dirName} -> $version'));

    await _manifests.setCargoPackageVersion(
      p.join(rootOf(Repo.cvlite), 'Cargo.toml'),
      v[Repo.cvlite]!,
    );

    final wxingManifest = p.join(rootOf(Repo.wxing), 'Cargo.toml');
    await _manifests.setCargoPackageVersion(wxingManifest, v[Repo.wxing]!);
    await _manifests.setCargoDependency(
      wxingManifest,
      'cvlite',
      'version = "${v[Repo.cvlite]}"',
    );

    await _manifests.setRustWorkspaceVersion(rootOf(Repo.rust), v[Repo.rust]!);
    // Both crates in the workspace that reach outside it.
    for (final crate in ['wxscan', 'wxscan-ffi']) {
      final manifest = p.join(rootOf(Repo.rust), 'crates/$crate/Cargo.toml');
      await _manifests.setCargoDependency(
        manifest,
        'cvlite',
        'version = "${v[Repo.cvlite]}"',
      );
      if (crate == 'wxscan') {
        await _manifests.setCargoDependency(
          manifest,
          'wxing',
          'version = "${v[Repo.wxing]}"',
        );
      }
    }

    for (final target in releasePlan.where(
      (t) => t.registry == Registry.pub,
    )) {
      await _manifests.setPubspecVersion(dirOf(target), v[Repo.dart]!);
    }
    // wxscan_live's constraint on wxscan has to move with it, or the newly
    // published plugin resolves against the previous scanner.
    await _manifests.setPubDependency(
      p.join(rootOf(Repo.dart), 'packages/wxscan_live'),
      'wxscan',
      '^${v[Repo.dart]}',
    );
  }

  // ---- dependency mode ----------------------------------------------------

  /// Switches `wxscan/rust` to pure crates.io versions.
  ///
  /// Run after every crate is published and before publishing wxscan.
  Future<void> releaseDeps() async {
    final version = await _manifests.readVersion(rootOf(Repo.rust));
    print('wxscan/rust -> crates.io $version');

    // Only the source key moves; `default-features` and the feature list stay
    // exactly as the development manifest had them. Which image decoders a
    // build carries is settled there, and a release that quietly dropped the
    // list would ship a different library from the one developed against.
    for (final dep in ['wxscan-ffi', 'wxscan']) {
      await _manifests.setCargoDependency(
        _coreRustManifest,
        dep,
        'version = "$version"',
      );
    }
    await _manifests.setCargoPatch(_coreRustManifest, null);
  }

  /// Puts the path dependencies and the patch block back.
  ///
  /// froom's kit has no equivalent, because froom has nothing outside pub.dev.
  /// Here it is not optional: on a version dependency, local edits to the Rust
  /// sources are invisible to the Flutter build, so leaving a release-mode
  /// manifest behind silently breaks development until someone works out why
  /// their Rust changes stopped taking effect.
  Future<void> restoreDev() async {
    final up = _coreToWorkspace;
    print('wxscan/rust -> path dependencies under $up');

    for (final dep in ['wxscan-ffi', 'wxscan']) {
      await _manifests.setCargoDependency(
        _coreRustManifest,
        dep,
        'path = "${p.join(up, Repo.rust.dirName, 'crates', dep)}"',
      );
    }

    // wxscan-ffi and wxscan declare cvlite and wxing by version, so without
    // this the path dependencies above resolve into crates.io for the two
    // general-purpose crates and pick up whatever is published there — or
    // nothing at all, before the first release.
    await _manifests.setCargoPatch(
      _coreRustManifest,
      {
        for (final crate in [Repo.cvlite, Repo.wxing])
          crate.dirName: '{ path = "${p.join(up, crate.dirName)}" }',
      },
      comment:
          'Development only, removed by `publish_kit release-deps`.\n'
          '\n'
          'This lives in the manifest rather than in .cargo/config.toml because\n'
          'the build hook invokes cargo with --manifest-path from the Flutter\n'
          "project's directory, and cargo discovers config files from the\n"
          'process working directory, not from the manifest. A config file next\n'
          'to this one would simply never be read.',
    );
  }

  // ---- publish ------------------------------------------------------------

  /// Publishes every target in [releasePlan] that is not already up.
  ///
  /// Re-runnable: anything the registry already has is skipped, so an
  /// interrupted chain resumes rather than restarting.
  Future<void> publish({Set<String>? only}) async {
    // Before anything is uploaded, because an upload cannot be taken back.
    final planIssues = planProblems();
    if (planIssues.isNotEmpty) {
      throw StateError(
        'The release plan is not publishable:\n  ${planIssues.join('\n  ')}',
      );
    }

    final targets = only == null
        ? releasePlan
        : releasePlan.where((t) => only.contains(t.id) || only.contains(t.name));

    if (targets.isEmpty) {
      throw StateError('No targets matched --only.');
    }

    for (final target in targets) {
      final version = await versionOf(target);

      final published = await _registry.isPublished(target, version);
      if (published == null) {
        throw StateError(
          'Could not reach ${target.registry.host} to check whether '
          '${target.id} $version is already published. Refusing to guess — '
          're-run when the registry is reachable.',
        );
      }
      if (published) {
        print('--- ${target.id} $version already published, skipping');
        continue;
      }

      print('\n>>> Publishing ${target.id} $version to ${target.registry.host}');
      await _run(target);

      if (dryRun) continue;

      // Nothing downstream can resolve this until the registry serves it.
      await _registry.waitUntilPublished(target, version, log: print);
    }

    print('\nDone.');
  }

  Future<void> _run(Target target) async {
    final (executable, arguments, workingDirectory) = switch (target.registry) {
      Registry.cargo => (
        'cargo',
        [
          'publish',
          '-p',
          target.name,
          if (allowDirty) '--allow-dirty',
          if (dryRun) '--dry-run',
        ],
        rootOf(target.repo),
      ),
      Registry.pub => (
        // wxscan pulls in the Flutter SDK and cannot be resolved by plain dart.
        _needsFlutter(dirOf(target)) ? 'flutter' : 'dart',
        ['pub', 'publish', if (dryRun) '--dry-run' else '--force'],
        dirOf(target),
      ),
    };

    print('    \$ $executable ${arguments.join(' ')}   (in $workingDirectory)');

    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.inheritStdio,
    );
    final exitCode = await process.exitCode;

    if (exitCode != 0) {
      throw StateError(
        'Publishing ${target.id} failed with exit code $exitCode. Nothing '
        'after it was attempted; fix the cause and re-run to resume.',
      );
    }
  }

  static bool _needsFlutter(String packageDir) {
    final pubspec = File(p.join(packageDir, 'pubspec.yaml'));
    return pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('sdk: flutter');
  }

  void close() => _registry.close();
}
