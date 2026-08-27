# wxscan publish-kit

Release driver for wxscan. Ported from [wilinz/froom](https://github.com/wilinz/froom/tree/develop/publish-kit)'s
publish-kit, which publishes four packages from one repository to pub.dev.

wxscan publishes **eight targets from four repositories to two registries**, so
what carried over is the shape — ordered publishing, waiting for the registry
between steps, skipping what is already up — and the rest is new.

## What changed from froom's kit

| | froom | here |
|---|---|---|
| Registries | pub.dev | crates.io **and** pub.dev |
| Repositories | one | four (see below) |
| Release order | hardcoded in `publishOrder` | data, in `lib/src/plan.dart` |
| "Already published?" | `dart pub publish --dry-run` + grep stderr | registry HTTP API |
| Back to dev mode | — | `restore-dev` |
| Branch handling | creates release branches, merges, tags, force-switches | none |

Three of those are worth explaining.

**Registry API instead of grepping a dry run.** froom's kit answers "is this
already published?" by packing the whole package and looking for `already
exists` in stderr. That is slow, and it cannot tell "already published" apart
from "packaging is broken" — both exit non-zero. Both registries answer
directly: `crates.io/api/v1/crates/<name>/<version>` and
`pub.dev/api/packages/<name>/versions/<version>`, 200 or 404. When the registry
is *unreachable* this kit stops rather than guessing, because reading an outage
as "not published yet" means attempting a duplicate upload.

**No branch management.** froom's kit creates a release branch, merges to main,
tags, pushes, and re-runs `git checkout` during the wait loop to correct for a
user switching branches. Two repositories neither of which has a commit yet is
the worst possible input for that. Do git by hand.

**No `all`.** froom's kit has one. This chain crosses two registries and cannot
be undone once a version is up — a published crate version is permanent even if
yanked. Every step is run deliberately.

## The repositories

Split along what each piece is *for*, not along what artifact it produces:

| Repository | Holds | WeChat-specific? |
|---|---|---|
| `cvlite` | OpenCV imgproc port, zero dependencies | no |
| `wxing` | the ZXing fork, QR decoding | no |
| `wxscan-rs` | `wxscan`, `-tflite`, `-ffi` | yes |
| `wxscan` | `wxscan`, `wxscan_live` (Dart) | yes |

The three crates in `wxscan-rs` are three facets of one thing — the backend,
the orchestration, the C ABI — and have to ship at one version, so they stay in
one workspace. The weights are in none of them; they live in
[wxscan-weights](https://github.com/wilinz/wxscan-weights), because a registry
is the wrong place to version two megabytes that most callers already have. The two general-purpose crates are useful to anyone
and stand alone.

All five checkouts, plus `wxscan-dev`, sit side by side under one parent
directory; the kit finds that parent by walking up from wherever it is run.

## The order

```
crate:cvlite → crate:wxing → crate:wxscan-tflite
             → crate:wxscan → crate:wxscan-ffi
             → pub:wxscan → pub:wxscan_live
```

This is not a preference. `packages/wxscan/rust` depends on `wxscan-ffi` and
the `wxscan` crate, and transitively on `cvlite` and `wxing`. Nobody installing from
pub.dev has those checkouts, so the build hook cannot build until all five
crates are on crates.io and the dependencies are versions instead of paths.

## Versions

One `version.txt` per repository, four in total, not one shared file. Splitting
the repositories was the whole point of being able to move them independently;
a shared number would put that straight back. `update-version` also carries each
number into every constraint the other repositories place on it.

## Local development across repositories

Each repository commits version dependencies on its siblings — the only form
installable from a registry. `wxscan-dev/link.sh` writes gitignored path
overrides so local checkouts still build against each other. See that repo's
README; the Dart package is the one exception and is handled by `release-deps`
and `restore-dev` here.

## Commands

```bash
cd publish-kit && dart pub get

dart run publish_kit check           # report blockers, change nothing
dart run publish_kit update-version  # version.txt -> manifests
dart run publish_kit release-deps    # wxscan/rust -> crates.io versions
dart run publish_kit publish         # everything not already up, in order
dart run publish_kit restore-dev     # wxscan/rust -> path dependencies
```

Add `--dry-run` to any of them. `--allow-dirty` is needed for cargo until
`wxscan-rs` has a commit. `--only crate:cvlite` limits publishing to one target.

`publish` is re-runnable: anything the registry already serves is skipped, so an
interrupted chain resumes instead of restarting.

## Full release

```bash
dart run publish_kit check
dart run publish_kit update-version
# commit, tag, push both repos by hand
dart run publish_kit publish --allow-dirty --only crate:cvlite \
  --only crate:wxing --only crate:wxscan-tflite \
  --only crate:wxscan --only crate:wxscan-ffi
dart run publish_kit release-deps
dart run publish_kit publish          # the two pub packages
dart run publish_kit restore-dev      # ← do not skip
```

**`restore-dev` is not optional.** On a version dependency, local edits to the
Rust sources are invisible to the Flutter build. Leaving a release-mode manifest
behind silently breaks development until someone works out why their Rust
changes stopped taking effect.

## Deliberately not handled

- **`dependency_overrides` in `packages/wxscan_live/pubspec.yaml`** is left in
  place. It points `wxscan` back at this checkout for development. Consumers
  ignore overrides entirely, so publishing with it costs one pub hint and
  nothing else — cheaper than a toggle that has to strip and restore a commented
  block on every release.
- **CHANGELOG syncing.** froom's kit copies a root CHANGELOG entry into each
  package and refuses to run without one. Neither wxscan repo has a root
  CHANGELOG, and the two Dart packages document different things.
- **README copying.** froom has one README across four packages; the crates and
  the plugin here document different surfaces.
