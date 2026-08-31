/// Builds the Rust library and bundles the TFLite C library it needs.
///
/// This is the only place in the repository that builds native code. One hook
/// covers every platform, in place of the CocoaPods, Gradle and CMake glue a
/// Flutter plugin would need, and because it is a build hook it also works for
/// plain `dart run` and `dart test`.
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

import 'package:wxscan/src/hook/options.dart';
import 'package:wxscan/src/hook/tflite.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // The hook is also run in modes that want no native code at all, and
    // reading the code configuration in one of those throws.
    if (!input.config.buildCodeAssets) return;

    final code = input.config.code;
    // What the application asked for in its own pubspec: which image decoders
    // to carry, and how cargo should trade size against speed.
    final options = readOptions(input, code.targetOS);
    final tflite = await fetchTflite(
      os: code.targetOS,
      architecture: code.targetArchitecture,
      // Device and simulator are different archives. The configuration says
      // which one this build is for; reading it off the environment does not
      // work, because the hook runner scrubs what Xcode sets.
      iosSdk: code.targetOS == OS.iOS ? code.iOS.targetSdk : null,
      packageRoot: Directory.fromUri(input.packageRoot),
      cache: Directory.fromUri(input.outputDirectoryShared.resolve('tflite/')),
    );

    await RustBuilder(
      assetName: 'src/bindings.dart',
      // The image formats, and nothing but: every feature this crate has is
      // one, and which of them a build carries is the application's to say.
      enableDefaultFeatures: false,
      features: options.features,
      // The hook runner scrubs the environment, so the linker's search path
      // cannot be inherited; build.rs reads these instead.
      extraCargoEnvironmentVariables: {
        ...options.cargoEnvironment,
        'TFLITE_LIB_DIR': tflite.directory.path,
        'TFLITE_LIB_NAME': tflite.linkName,
        'TFLITE_LINK_STATIC': tflite.isStatic ? '1' : '0',
        // Rust's Apple targets carry deployment targets from when they were
        // added - iOS 10 for aarch64-apple-ios - and nothing here would say
        // so: the link simply fails on `___chkstk_darwin`, a symbol libSystem
        // grew in iOS 13 that TFLite's objects, built for 13, reference. The
        // version Flutter is building for is right here in the configuration,
        // and rustc reads these two variables.
        if (code.targetOS == OS.iOS)
          'IPHONEOS_DEPLOYMENT_TARGET': '${code.iOS.targetVersion}',
        if (code.targetOS == OS.macOS)
          'MACOSX_DEPLOYMENT_TARGET': '${code.macOS.targetVersion}',
      },
    ).run(input: input, output: output);

    // A shared TFLite is bundled beside the Rust library; the Dart tooling
    // copies both into one directory and rewrites the dependency path, so no
    // rpath arrangement is needed. iOS is static and is already inside the
    // Rust library, so there is nothing to bundle.
    if (!tflite.isStatic) {
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: tflite.file.uri.pathSegments.last,
          linkMode: DynamicLoadingBundled(),
          file: tflite.file.uri,
        ),
      );
    }
    output.dependencies.add(tflite.file.uri);
  });
}
