# wxscan

QR scanning: the `wechat_qrcode` algorithm — CNN detection, super resolution,
decoding — ported to Rust, with Dart and Flutter packages over it. No OpenCV.

This repository holds the Dart side and the release driver. The Rust lives in
sibling repositories, checked out **beside this one under a shared parent**.
That layout is not a suggestion: `publish-kit` and `../wxscan-dev/link.sh` both
find their siblings by walking up from wherever they are run, so moving or
renaming a checkout breaks both.

```
<parent>/
├── wxscan/          ← this repository
├── cvlite/          OpenCV imgproc port, no dependencies      → crates.io
├── wxing/           the ZXing fork, QR decoding               → crates.io
├── wxscan-rs/       wxscan, -tflite, -ffi, -wasm              → crates.io
├── wxscan-weights/  detect.tflite, sr.tflite, and their scripts
├── wxscan-dev/      link.sh, which wires the checkouts together locally
└── litert-builds/, wxscan-litert-wasm/   TFLite build recipes
```

`cvlite` and `wxing` are general-purpose and know nothing about WeChat. The
crates in `wxscan-rs` are one thing seen from three sides — backend,
orchestration, C ABI — and ship at one version, which is why they share a
workspace.

The weights are in no package. A registry is the wrong place to version two
megabytes most callers already have, so nothing embeds them and nothing
downloads them at build time.

## Releasing — read this before touching a registry

**Never run `dart pub publish` or `cargo publish` by hand.** Everything goes
through `publish-kit`. Seven targets, two registries, and an order that is a
dependency graph rather than a preference.

```bash
cd publish-kit && dart pub get
dart run publish_kit check           # reports every blocker, changes nothing
dart run publish_kit update-version  # version.txt -> every manifest
dart run publish_kit release-deps    # packages/wxscan/rust -> crates.io versions
dart run publish_kit publish         # what is not already up, in order
dart run publish_kit restore-dev     # ← not optional
```

`--dry-run` works on all of them; `--only <target>` limits `publish`; `publish`
is re-runnable, since anything the registry already serves is skipped.

**`release-deps` is the step that silently ruins a release.** The checkout
commits development mode: `packages/wxscan/rust/Cargo.toml` carries
`path = "../../../../wxscan-rs/..."` dependencies and a `[patch.crates-io]`
block naming the sibling checkouts. That form builds perfectly — and only here.
Someone installing from pub.dev has no such directories, so the build hook
cannot build at all. This is exactly how wxscan 0.1.4 shipped broken and had to
be replaced by 0.1.5.

`restore-dev` afterwards is equally required, and belongs in the release commit
or one right after it, because **the committed state is development mode** —
only the published archive carries crates.io versions. On a version dependency,
local edits to the Rust sources become invisible to the Flutter build, and the
symptom is "my changes stopped taking effect" with no error anywhere.

**Two guards enforce this, so it does not rest on remembering.**
`publish_kit publish` refuses to upload `pub:wxscan` while that manifest is in
development mode — `check` reports it as a note, because it is the normal
committed state, but at the moment of upload it is fatal. And
`tool/guard_publish.sh`, wired up as a Claude Code PreToolUse hook in
`.claude/settings.json`, refuses a direct `dart pub publish`, `flutter pub
publish` or `cargo publish` and points at the kit instead. The kit spawns the
real publish command itself, which never passes through that hook, so a proper
release is unaffected. `--dry-run` is always allowed.

**Verify outside the workspace before uploading.** A local build proves nothing
about a published package: what differs is the manifest form, and it is
invisible from in here. Copy the package to a short path with no siblings and
build it there.

```bash
rm -rf /tmp/iso && mkdir /tmp/iso
rsync -a --exclude .dart_tool --exclude rust/target --exclude build \
      --exclude pubspec.lock packages/wxscan/ /tmp/iso/w/
cd /tmp/iso/w && dart pub get && dart test
```

A long path makes `install_name_tool` fail with "larger updated load commands
do not fit" — that is the path, not the package. Keep it short.

Versions live in one `version.txt` per repository, four in all, deliberately
not shared: being able to move the repositories independently was the point of
splitting them.

`publish` tags each repository it released, `v<version>` on HEAD, with the
changelog entry as the tag body where there is one. It creates no branches and
no commits, and it pushes nothing — it prints the `git push` line per
repository, because these are four repositories and one push does not reach
them all. `publish_kit tag` does the same on its own, which is what a release
that already went out untagged needs; both are re-runnable, and `check` reports
a version with no tag. 0.1.4 and 0.1.5 shipped untagged because this step
existed only in this file.

## Working across the repositories

Each repository commits *version* dependencies on its siblings, the only form a
registry can install. `../wxscan-dev/link.sh` writes gitignored
`.cargo/config.toml` path overrides so local checkouts still build against each
other, including at versions never published. Run it once after cloning:

```bash
../wxscan-dev/link.sh          # and --unlink to undo
```

The Dart package is the exception: its overrides are `publish-kit`'s business,
via `release-deps` and `restore-dev`.

## The packages

`packages/wxscan` is a plain Dart package, not a Flutter plugin. Its
[build hook](https://dart.dev/tools/hooks) compiles the Rust and fetches the
TFLite library, so it works under `dart run` and `dart test` with no Flutter
involved, and there are no podspec, Gradle or CMake files to maintain.
`packages/wxscan_live` is the camera in front of it, and is a plugin.

```bash
cd packages/wxscan       && dart test          # builds the Rust too
cd packages/wxscan_live  && flutter analyze
cd packages/wxscan_live/example && flutter build macos --debug
```

The hook needs rustup on `PATH`; the compiler and targets are pinned in
`packages/wxscan/rust/rust-toolchain.toml` and installed on first build. A
target missing from that file is a failure at the far end of a long build, so
add one when adding a platform — `flutter build ios --simulator` wants
`x86_64-apple-ios` beside the arm64 slice.

Device and simulator take different TFLite archives, and the simulator's is
universal, which rustc will not read. Both are handled in
`packages/wxscan/lib/src/hook/tflite.dart`, which takes the answer from
`IOSSdk` in the build configuration — not from Xcode's environment, which the
hook runner scrubs.

`wxscan_live` ships both Apple build systems: `ios/wxscan_live/Package.swift`
for the Swift Package Manager and `ios/wxscan_live.podspec` for CocoaPods,
reading the same sources under `ios/wxscan_live/Sources/`. `wxscan.h` is a
target of its own because a Swift Package Manager target cannot mix Swift and
C; under CocoaPods it arrives through the pod's umbrella header instead, which
is why the Swift files import it behind `#if canImport(wxscan_c)`. Touching
either one means building both, on iOS device, iOS simulator and macOS.

## Conventions

- Run `dart format .` before publishing; pub.dev scores formatting.
- Package descriptions must be 60-180 characters, or pub.dev takes 10 points.
- `tool/check_links.py` checks every link in every README.
- READMEs come in pairs, `README.md` and `README.zh-CN.md`. Change both.
- Cross-package links in a *published* README point at pub.dev with the GitHub
  source beside it, since relative paths do not survive pub.dev's renderer.
- `pana` is the arbiter of package quality. Run it rather than guessing at a
  score: `dart pub global run pana --no-warning packages/wxscan`.
