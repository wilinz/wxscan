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

import 'tflite.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // The hook is also run in modes that want no native code at all, and
    // reading the code configuration in one of those throws.
    if (!input.config.buildCodeAssets) return;

    final code = input.config.code;
    final tflite = await fetchTflite(
      os: code.targetOS,
      architecture: code.targetArchitecture,
      packageRoot: Directory.fromUri(input.packageRoot),
      cache: Directory.fromUri(input.outputDirectoryShared.resolve('tflite/')),
    );

    await RustBuilder(
      assetName: 'src/bindings.dart',
      // The hook runner scrubs the environment, so the linker's search path
      // cannot be inherited; build.rs reads these instead.
      extraCargoEnvironmentVariables: {
        'TFLITE_LIB_DIR': tflite.directory.path,
        'TFLITE_LIB_NAME': tflite.linkName,
        'TFLITE_LINK_STATIC': tflite.isStatic ? '1' : '0',
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
