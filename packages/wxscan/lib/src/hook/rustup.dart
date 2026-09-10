/// Making sure a `rustup` exists before the Rust build asks for one.
///
/// `native_toolchain_rust` looks for `rustup` on the PATH and then at
/// `~/.cargo/bin/rustup`, and stops the build if neither is there. That is a
/// fair thing for a Rust project to demand, but this package is a pub
/// dependency: someone adding it to a Flutter application has no reason to
/// have a Rust toolchain, and "install rustup" is a strange thing for
/// `flutter build` to say.
///
/// So when there is no rustup, one is fetched into the build directory and
/// used from there. Nothing is installed into the home directory and nothing
/// outside the build directory is touched; deleting the build directory undoes
/// all of it.
///
/// The toolchain itself is not chosen here. rustup reads
/// `rust/rust-toolchain.toml` — the pinned channel and the target list — and
/// installs what it says on first use, exactly as it would for a developer who
/// had rustup already.
library;

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';

/// Where a bootstrapped rustup lives, relative to the shared output directory.
///
/// Shared rather than per-target: a Flutter build runs this hook once per
/// architecture, and they would otherwise each fetch their own copy of the
/// same toolchain, which is hundreds of megabytes apiece.
const _installDirName = 'rustup';

/// Set on the re-executed hook so that a second failure to find rustup is
/// reported instead of bootstrapping again forever.
const _guardVariable = 'WXSCAN_RUSTUP_BOOTSTRAPPED';

/// Ensures the build that follows can find a `rustup`.
///
/// Returns true if the caller should go on and build. Returns false when the
/// build has already been done by a re-executed copy of this hook, which is
/// what happens after a rustup is bootstrapped: the child process wrote the
/// hook output, and this one must not write over it.
///
/// [args] is the hook's own argument list, which carries `--config`; it is
/// read for the output directory and handed to the child unchanged.
Future<bool> ensureRustup(List<String> args) async {
  if (_systemRustup() != null) return true;

  if (Platform.environment[_guardVariable] == '1') {
    throw StateError(
      'wxscan: rustup was installed into the build directory but still '
      'cannot be run. Install Rust yourself from https://rustup.rs and '
      'build again.',
    );
  }

  final home = Directory.fromUri(
    _sharedOutputDirectory(args).resolve('$_installDirName/'),
  );
  final rustup = await _bootstrap(home);

  // The build cannot simply be run from here: the PATH of a running process
  // is fixed, and that is where `native_toolchain_rust` looks. So the hook
  // runs itself again, with the new rustup on the PATH of the child, and that
  // copy does the build and writes the output.
  final binDirectory = File(rustup).parent.path;
  final process = await Process.start(
    Platform.resolvedExecutable,
    [Platform.script.toFilePath(), ...args],
    mode: ProcessStartMode.inheritStdio,
    environment: {
      'PATH': '$binDirectory${_pathSeparator}${_currentPath()}',
      'RUSTUP_HOME': _rustupHome(home).path,
      'CARGO_HOME': _cargoHome(home).path,
      _guardVariable: '1',
    },
  );
  final code = await process.exitCode;
  if (code != 0) {
    throw StateError('wxscan: the Rust build failed (exit code $code)');
  }
  return false;
}

/// The rustup already on this machine, if there is one.
///
/// The same two places `native_toolchain_rust` looks, asked the same way: by
/// running it. A `rustup` on the PATH that cannot be executed is no rustup.
String? _systemRustup() {
  final home = Platform.isWindows
      ? Platform.environment['USERPROFILE']
      : Platform.environment['HOME'];
  final candidates = [
    'rustup',
    if (home != null)
      '$home/.cargo/bin/rustup${Platform.isWindows ? '.exe' : ''}',
  ];
  for (final candidate in candidates) {
    try {
      final result = Process.runSync(candidate, ['--version']);
      if (result.exitCode == 0) return candidate;
    } on ProcessException {
      continue;
    }
  }
  return null;
}

/// Downloads `rustup-init` and runs it into [home].
///
/// Returns the path of the installed rustup. Does nothing if a previous build
/// already put one there.
Future<String> _bootstrap(Directory home) async {
  final rustup = File.fromUri(
    _cargoHome(
      home,
    ).uri.resolve('bin/rustup${Platform.isWindows ? '.exe' : ''}'),
  );

  home.createSync(recursive: true);
  // One lock for the whole thing: the hook runs once per target architecture
  // and those run at the same time, so without it several processes install
  // over each other into the same directory.
  final lock = File.fromUri(
    home.uri.resolve('install.lock'),
  ).openSync(mode: FileMode.write);
  try {
    // Blocking: the other process is installing the same thing, and what this
    // one wants is to carry on once that is done, not to fail.
    lock.lockSync(FileLock.blockingExclusive);
    if (rustup.existsSync()) return rustup.path;

    final installer = await _downloadInstaller(home);
    stdout.writeln('wxscan: no rustup found; installing one into ${home.path}');
    final result = await Process.run(
      installer.path,
      [
        '-y',
        // The point of putting it here is that nothing outside is touched:
        // no shell profile is edited and no PATH is rewritten.
        '--no-modify-path',
        // Nothing is chosen here. The first rustup call runs in the crate
        // directory, where `rust-toolchain.toml` says which channel and which
        // targets, and rustup installs that.
        '--default-toolchain',
        'none',
        '--profile',
        'minimal',
      ],
      environment: {
        'RUSTUP_HOME': _rustupHome(home).path,
        'CARGO_HOME': _cargoHome(home).path,
      },
    );
    if (result.exitCode != 0) {
      throw StateError(
        'wxscan: rustup-init failed with exit code ${result.exitCode}\n'
        '${result.stdout}\n${result.stderr}',
      );
    }
    if (!rustup.existsSync()) {
      throw StateError('wxscan: rustup-init left no rustup at ${rustup.path}');
    }
    return rustup.path;
  } finally {
    lock.closeSync();
  }
}

Directory _rustupHome(Directory home) =>
    Directory.fromUri(home.uri.resolve('rustup/'));

Directory _cargoHome(Directory home) =>
    Directory.fromUri(home.uri.resolve('cargo/'));

/// Fetches `rustup-init` for the machine this build runs on.
///
/// The digest is fetched from the `.sha256` the same release publishes beside
/// the binary. That is not a defence against a bad server — it is the same
/// server — but a truncated download is the failure that actually happens over
/// a slow connection, and it would otherwise be found by running it.
Future<File> _downloadInstaller(Directory home) async {
  final triple = _hostTriple();
  final name = 'rustup-init${Platform.isWindows ? '.exe' : ''}';
  final url = 'https://static.rust-lang.org/rustup/dist/$triple/$name';

  final published = utf8.decode(await _get(Uri.parse('$url.sha256')));
  final wanted = published.trim().split(RegExp(r'\s+')).first;

  final out = File.fromUri(home.uri.resolve(name));
  if (out.existsSync() && _sha256(out) == wanted) return out;

  final bytes = await _get(Uri.parse(url));
  final got = sha256.convert(bytes).toString();
  if (got != wanted) {
    throw StateError(
      'wxscan: checksum mismatch for $url\n'
      '  expected $wanted\n'
      '  got      $got',
    );
  }
  // Written beside and moved into place, so that an interrupted download is
  // never left under the name that says it finished.
  final part = File('${out.path}.part')..writeAsBytesSync(bytes);
  part.renameSync(out.path);
  if (!Platform.isWindows) {
    final chmod = Process.runSync('chmod', ['+x', out.path]);
    if (chmod.exitCode != 0) {
      throw StateError('wxscan: chmod +x ${out.path} failed: ${chmod.stderr}');
    }
  }
  return out;
}

Future<List<int>> _get(Uri url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    final response = await request.close();
    if (response.statusCode != 200) {
      throw StateError('wxscan: GET $url returned ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return bytes;
  } finally {
    client.close();
  }
}

String _sha256(File file) => sha256.convert(file.readAsBytesSync()).toString();

/// The rustup release for the machine running the build, not the one being
/// built for: this is the tool, not the toolchain.
String _hostTriple() {
  final os = OS.current;
  final architecture = Architecture.current;
  final triple = switch ((os.name, architecture.name)) {
    ('macos', 'arm64') => 'aarch64-apple-darwin',
    ('macos', 'x64') => 'x86_64-apple-darwin',
    ('linux', 'x64') => 'x86_64-unknown-linux-gnu',
    ('linux', 'arm64') => 'aarch64-unknown-linux-gnu',
    ('linux', 'arm') => 'armv7-unknown-linux-gnueabihf',
    ('windows', 'x64') => 'x86_64-pc-windows-msvc',
    ('windows', 'arm64') => 'aarch64-pc-windows-msvc',
    _ => null,
  };
  if (triple == null) {
    throw StateError(
      'wxscan: no rustup release for $os/$architecture. Install Rust '
      'yourself from https://rustup.rs and build again.',
    );
  }
  return triple;
}

String get _pathSeparator => Platform.isWindows ? ';' : ':';

String _currentPath() =>
    Platform.environment['PATH'] ?? Platform.environment['Path'] ?? '';

/// The `out_dir_shared` of the configuration this hook was called with.
///
/// Read straight out of the JSON rather than from a [BuildInput], because this
/// runs before `build()` is entered — the decision to re-execute has to be
/// made before anything writes the hook output.
Uri _sharedOutputDirectory(List<String> args) {
  final config = File(_configPath(args));
  final json = jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
  final shared = json['out_dir_shared'];
  if (shared is! String) {
    throw StateError('wxscan: no out_dir_shared in ${config.path}');
  }
  return Directory(shared).uri;
}

/// The `--config=<path>` the hook runner passes, in either of its two spellings.
String _configPath(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--config=')) {
      return args[i].substring('--config='.length);
    }
    if (args[i] == '--config' && i + 1 < args.length) return args[i + 1];
  }
  throw StateError('wxscan: the build hook was called without --config');
}
