/// The knobs an application turns in its own `pubspec.yaml`.
///
/// Two things about this package's native library are the application's to
/// decide rather than this package's: which image formats it will ever be
/// asked to decode, and how cargo should trade size against speed. Both are
/// answered in the pubspec that builds the application, under
/// `hooks: user_defines: wxscan:`, and read here.
///
/// ```yaml
/// hooks:
///   user_defines:
///     wxscan:
///       image_formats: [png, jpeg]
///       cargo_profile:
///         strip: symbols
/// ```
///
/// Every value is validated, and a wrong one stops the build saying what was
/// expected. The alternative is worse than it sounds: a misspelled format is a
/// decoder silently missing from the shipped library, and a misspelled cargo
/// key is an environment variable cargo ignores without a word.
library;

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// What the pubspec asked for, in the form the Rust build takes it.
class RustOptions {
  RustOptions({required this.features, required this.cargoEnvironment});

  /// Cargo features for `wxscan_core`, which are the image formats.
  final List<String> features;

  /// `CARGO_PROFILE_RELEASE_*` variables, which override the `[profile.release]`
  /// in `rust/Cargo.toml` — cargo reads its configuration from the environment
  /// ahead of the manifest, so this is the one way to reach a profile from
  /// outside the crate.
  final Map<String, String> cargoEnvironment;
}

/// Every format that can be asked for, and what it costs.
///
/// The three a camera and a photo picker write are first; the three after them
/// arrive from somewhere else — webp off the web, bmp out of a screenshot —
/// and HEIC is most of an Apple photo library and the expensive one, being a
/// whole HEVC decoder.
const _formats = {'png', 'jpeg', 'gif', 'webp', 'bmp', 'tiff', 'heic'};

/// What a build gets when the pubspec says nothing.
///
/// Everything, which is what this package carried before any of it was
/// configurable — except on Apple, where ImageIO is lent to the library at
/// startup and already reads webp, bmp, tiff and HEIC. Compiling those in
/// there too would be 570 KB and an HEVC decoder to answer a question the
/// system has already answered.
List<String> _defaultFormats(OS os) => [
      'png',
      'jpeg',
      'gif',
      if (os != OS.iOS && os != OS.macOS) ...['webp', 'bmp', 'tiff', 'heic'],
    ];

/// The `[profile.release]` keys that may be set, and what each accepts.
///
/// Cargo takes any of these from the environment, but it takes an unknown one
/// as nothing at all, so the set is closed here rather than passed through.
const _profileKeys = <String, Set<String>?>{
  // A scanner is a pipeline of loops over pixels, and this is the knob that
  // decides whether they are unrolled. `z` is about a third off the library
  // and, measured on a 1080p frame, three and a half times slower.
  'opt_level': {'0', '1', '2', '3', 's', 'z'},
  'lto': {'true', 'false', 'fat', 'thin', 'off'},
  // No set: any positive integer.
  'codegen_units': null,
  'strip': {'none', 'debuginfo', 'symbols'},
  // A panic in Rust called from Dart has nowhere to unwind to, so `abort` is
  // the honest setting as well as the smaller one — but it turns what was an
  // error crossing the boundary into the process ending, which is the
  // application's call and not this package's.
  'panic': {'unwind', 'abort'},
};

/// Reads and validates what the application asked for.
RustOptions readOptions(BuildInput input, OS os) => RustOptions(
      features: _readFormats(input.userDefines['image_formats'], os),
      cargoEnvironment: _readProfile(input.userDefines['cargo_profile']),
    );

List<String> _readFormats(Object? value, OS os) {
  if (value == null) return _defaultFormats(os);
  if (value is! List) {
    throw FormatException(
      'wxscan: hooks.user_defines.wxscan.image_formats must be a list of '
      'format names, one or more of ${_formats.join(', ')} — or left out, '
      'for all of them. Got: $value',
    );
  }
  final asked = value.map((e) => '$e'.trim().toLowerCase()).toList();
  final unknown = asked.where((f) => !_formats.contains(f)).toList();
  if (unknown.isNotEmpty) {
    throw FormatException(
      'wxscan: unknown image format${unknown.length > 1 ? 's' : ''} in '
      'hooks.user_defines.wxscan.image_formats: ${unknown.join(', ')}.\n'
      'Known formats: ${_formats.join(', ')}. `jpg` is spelled `jpeg` here, '
      'after the crate that decodes it.',
    );
  }
  // Not an error, and not silently accepted either: nothing decodes, every
  // picture comes back as an unsupported format, and scanning pixels straight
  // from a camera still works. That is a real thing to want and a strange
  // thing to arrive at by accident.
  return asked.toSet().toList();
}

Map<String, String> _readProfile(Object? value) {
  if (value == null) return const {};
  if (value is! Map) {
    throw FormatException(
      'wxscan: hooks.user_defines.wxscan.cargo_profile must be a map of '
      '[profile.release] keys — ${_profileKeys.keys.join(', ')}. Got: $value',
    );
  }

  final environment = <String, String>{};
  value.forEach((key, raw) {
    final name = '$key';
    if (!_profileKeys.containsKey(name)) {
      throw FormatException(
        'wxscan: unknown cargo profile key '
        'hooks.user_defines.wxscan.cargo_profile.$name.\n'
        'Known keys: ${_profileKeys.keys.join(', ')}.',
      );
    }
    final asked = '$raw'.trim();
    final allowed = _profileKeys[name];
    if (allowed != null && !allowed.contains(asked)) {
      throw FormatException(
        'wxscan: hooks.user_defines.wxscan.cargo_profile.$name must be one of '
        '${allowed.join(', ')}. Got: $asked',
      );
    }
    if (allowed == null && (int.tryParse(asked) ?? 0) < 1) {
      throw FormatException(
        'wxscan: hooks.user_defines.wxscan.cargo_profile.$name must be a '
        'positive integer. Got: $asked',
      );
    }
    environment['CARGO_PROFILE_RELEASE_${name.toUpperCase()}'] = asked;
  });
  return environment;
}
