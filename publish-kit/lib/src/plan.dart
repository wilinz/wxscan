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
  rust('wxscan-rs', 'The WeChat algorithm: wxscan, -tflite, -ffi'),
  dart('wxscan', 'The Dart side: wxscan, wxscan_live');

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

  /// Ids of other targets in this plan that must be published first.
  ///
  /// Ids rather than names, because two targets are called `wxscan` and a bare
  /// name cannot say which. Checked by [planProblems].
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
    deps: ['crate:cvlite'],
  ),
  // ---- the algorithm workspace -----------------------------------------
  // The weights are not here and are in no crate at all; they live in the
  // wxscan-weights repository, because a registry is the wrong place to
  // version two megabytes of data most callers already have.
  Target(
    name: 'wxscan-tflite',
    registry: Registry.cargo,
    repo: Repo.rust,
    dir: 'crates/wxscan-tflite',
  ),
  Target(
    name: 'wxscan',
    registry: Registry.cargo,
    repo: Repo.rust,
    dir: 'crates/wxscan',
    deps: ['crate:cvlite', 'crate:wxing', 'crate:wxscan-tflite'],
  ),
  Target(
    name: 'wxscan-ffi',
    registry: Registry.cargo,
    repo: Repo.rust,
    dir: 'crates/wxscan-ffi',
    deps: ['crate:cvlite', 'crate:wxscan'],
  ),
  // ---- pub.dev ---------------------------------------------------------
  // The pub package `wxscan` and the crate `wxscan` are different things
  // sharing a name — one is the scanner as Dart sees it, the other as cargo
  // does — and [registry] is what tells them apart. Nothing here resolves a
  // dependency by name, so the two can coexist.
  //
  // wxscan's build hook compiles packages/wxscan/rust, which depends on
  // wxscan-ffi and the wxscan crate and transitively on cvlite and wxing.
  // Until all four are on crates.io the hook only builds on a machine that
  // happens to have every sibling checkout, which is why the crates all come
  // first.
  Target(
    name: 'wxscan',
    registry: Registry.pub,
    repo: Repo.dart,
    dir: 'packages/wxscan',
    deps: ['crate:wxscan-ffi'],
  ),
  Target(
    name: 'wxscan_live',
    registry: Registry.pub,
    repo: Repo.dart,
    dir: 'packages/wxscan_live',
    deps: ['pub:wxscan'],
  ),
];

/// What is wrong with [releasePlan], or empty when nothing is.
///
/// The list order is the publishing order and `deps` is the claim that the
/// order is right — but nothing read `deps`, so the claim was decoration. A
/// target moved above one it depends on would have been caught by crates.io
/// rejecting the upload, three crates into a release that cannot be taken
/// back. Checking it costs a loop, and runs before anything is uploaded.
List<String> planProblems() {
  final problems = <String>[];
  final seen = <String>{};
  for (final target in releasePlan) {
    if (!seen.add(target.id)) {
      problems.add('${target.id} appears twice');
    }
    for (final dep in target.deps) {
      if (!releasePlan.any((t) => t.id == dep)) {
        problems.add('${target.id} depends on $dep, which is not in the plan');
      } else if (!seen.contains(dep)) {
        // Either later in the list or the target itself; both mean the order
        // publishes it before what it needs.
        problems.add('${target.id} is published before $dep, which it needs');
      }
    }
  }
  return problems;
}
