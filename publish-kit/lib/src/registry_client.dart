import 'dart:async';
import 'dart:io';

import 'plan.dart';

/// Asks the registries whether a given version is already up.
///
/// froom's kit answered this by running `dart pub publish --dry-run` and
/// grepping stderr for "already exists". That repacks the whole package to
/// answer a yes/no question, and it cannot tell "already published" apart from
/// "packaging is broken" — both are a non-zero exit. Both registries expose the
/// fact directly, so ask them.
class RegistryClient {
  RegistryClient({this.userAgent = 'wxscan-publish-kit (github.com/wilinz)'});

  /// crates.io rejects requests without one, so it is not optional.
  final String userAgent;

  final HttpClient _client =
      HttpClient()..connectionTimeout = const Duration(seconds: 20);

  Uri _versionUrl(Target target, String version) => switch (target.registry) {
    Registry.cargo => Uri.https(
      'crates.io',
      '/api/v1/crates/${target.name}/$version',
    ),
    Registry.pub => Uri.https(
      'pub.dev',
      '/api/packages/${target.name}/versions/$version',
    ),
  };

  /// Whether [version] of [target] is live.
  ///
  /// Returns null when the question could not be answered — no network, a 5xx,
  /// a timeout. Callers must not read null as "no": treating an outage as
  /// "not published yet" turns into a duplicate publish attempt.
  Future<bool?> isPublished(Target target, String version) async {
    try {
      final request = await _client.getUrl(_versionUrl(target, version));
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      final response = await request.close();
      await response.drain<void>();

      return switch (response.statusCode) {
        200 => true,
        404 => false,
        _ => null,
      };
    } on Exception {
      return null;
    }
  }

  /// Blocks until [version] of [target] is visible, or until [timeout].
  ///
  /// Both registries take a moment to make a new version resolvable after the
  /// upload returns, and publishing the next target before then fails on a
  /// dependency that "does not exist". Polling here is what makes the chain
  /// unattended.
  Future<void> waitUntilPublished(
    Target target,
    String version, {
    Duration interval = const Duration(seconds: 15),
    Duration timeout = const Duration(minutes: 15),
    void Function(String message)? log,
  }) async {
    final deadline = DateTime.now().add(timeout);
    var attempt = 0;

    while (DateTime.now().isBefore(deadline)) {
      attempt++;
      final published = await isPublished(target, version);
      if (published == true) {
        log?.call('  ${target.id} $version is live on ${target.registry.host}');
        return;
      }

      final remaining = deadline.difference(DateTime.now());
      log?.call(
        '  attempt $attempt: ${target.id} $version not visible yet on '
        '${target.registry.host}'
        '${published == null ? " (registry unreachable)" : ""}'
        ' — ${remaining.inMinutes}m left',
      );
      await Future<void>.delayed(interval);
    }

    throw StateError(
      'Timed out after ${timeout.inMinutes}m waiting for ${target.id} $version '
      'to appear on ${target.registry.host}. It may still land; re-run the '
      'same command to pick up where this left off.',
    );
  }

  void close() => _client.close(force: true);
}
