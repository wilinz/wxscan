/// The release graph, as data.
///
/// wxscan ships from four repositories to two registries, and the order is not
/// a preference but a hard constraint: a crate cannot be published while any
/// crate it depends on is missing from crates.io, and the Dart package cannot
/// be published while its Rust side still points at sibling checkouts instead
/// of released versions.
library;

/// Which registry a target is published to.
enum Registry {
  cargo('crates.io'),
  pub('pub.dev');

  const Registry(this.host);

  /// Human-readable name, used in log lines.
  final String host;
}

/// The four repositories, split along what each piece is *for*.
///
/// cvlite and wxing are not specific to the WeChat algorithm and are useful to
/// anyone, so they stand alone. The four crates inside wxscan-rs are four
/// facets of one thing — the weights, the backend, the orchestration and the C
/// ABI — and have to move together, so they stay in one workspace.
enum Repo {
  cvlite('cvlite', 'General-purpose OpenCV imgproc functions'),
  wxing('wxing', 'General-purpose QR decoding, the ZXing fork'),
  rust('wxscan-rs', 'The WeChat algorithm: wxscan, -tflite, -models, -ffi'),
  dart('wxscan', 'The Flutter plugin: wxscan_core, wxscan');

  const Repo(this.dirName, this.summary);

  /// Directory name under the shared parent that holds all checkouts.
  final String dirName;

  final String summary;
}

/// One publishable unit.
class Target {
  const Target({
    required this.name,
    required this.registry,
    required this.repo,
    this.dir = '.',
    this.deps = const [],
  });

  /// The name it is published under. Cargo crates use hyphens, pub packages
  /// underscores, so this is also what distinguishes `wxscan` the crate from
  /// `wxscan` the pub package.
  final String name;

  final Registry registry;
  final Repo repo;

  /// Directory holding the manifest, relative to the repo root. The two
  /// standalone crates are their own repository, hence the default.
  final String dir;

  /// Names of other targets in this plan that must be published first.
  final List<String> deps;

  /// The two `wxscan` entries collide by name; this disambiguates them in
  /// logs and in `--only`.
  String get id => '${registry == Registry.cargo ? "crate" : "pub"}:$name';

  @override
  String toString() => id;
}

/// The full order. Publishing walks this list front to back; every target's
/// `deps` appear before it.
const List<Target> releasePlan = [
  // ---- standalone crates, one repository each --------------------------
  Target(name: 'cvlite', registry: Registry.cargo, repo: Repo.cvlite),
  Target(
    name: 'wxing',
    registry: Registry.cargo,
    repo: Repo.wxing,
    deps: ['cvlite'],
  ),
  // ---- the algorithm workspace -----------------------------------------
  // Neither of these two depends on the other; they are only ordered before
  // `wxscan`, which optionally depends on both.
  Target(
    name: 'wxscan-tflite',
    registry: Registry.cargo,
    repo: Repo.rust,
    dir: 'crates/wxscan-tflite',
  ),
  Target(
    name: 'wxscan-models',
    registry: Registry.cargo,
    repo: Repo.rust,
    dir: 'crates/wxscan-models',
  ),
  Target(
    name: 'wxscan',
    registry: Registry.cargo,
    repo: Repo.rust,
    dir: 'crates/wxscan',
    deps: ['cvlite', 'wxing', 'wxscan-tflite', 'wxscan-models'],
  ),
  Target(
    name: 'wxscan-ffi',
    registry: Registry.cargo,
    repo: Repo.rust,
    dir: 'crates/wxscan-ffi',
    deps: ['cvlite', 'wxscan'],
  ),
  // ---- pub.dev ---------------------------------------------------------
  // wxscan_core's build hook compiles packages/wxscan_core/rust, which depends
  // on wxscan-ffi and wxscan and transitively on cvlite and wxing. Until all
  // four are on crates.io the hook only builds on a machine that happens to
  // have every sibling checkout, which is why the crates all come first.
  Target(
    name: 'wxscan_core',
    registry: Registry.pub,
    repo: Repo.dart,
    dir: 'packages/wxscan_core',
    deps: ['wxscan-ffi'],
  ),
  Target(
    name: 'wxscan',
    registry: Registry.pub,
    repo: Repo.dart,
    dir: 'packages/wxscan',
    deps: ['wxscan_core'],
  ),
];
