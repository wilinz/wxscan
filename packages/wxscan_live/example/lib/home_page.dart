/// What the application opens on: the things it can do, and no camera.
///
/// Opening straight into a live preview asks for the camera before the reader
/// has agreed to anything, and hides that decoding a picture is the other half
/// of what this library does. Each entry here starts one of the two paths.
library;

import 'package:flutter/material.dart';
import 'package:wxscan_live/wxscan_live.dart' show ScanResult;

import 'about_page.dart';
import 'pick_page.dart';
import 'result_page.dart';
import 'scan_page.dart';
import 'scanner.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// Whether the CNN detector loaded, or null while that is still unknown.
  ///
  /// Loading here rather than on the scanning screen means the answer is
  /// already in hand by the time either path is taken, and the reader can see
  /// which of the two engines they are about to use.
  bool? _nnEnabled;

  /// A decode is running; the entry shows it rather than appearing dead.
  bool _decoding = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await Scanner.init();
    if (mounted) setState(() => _nnEnabled = enabled);
  }

  Future<void> _openScanner() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ScanPage()));
  }

  Future<void> _decodeAPicture() async {
    if (_decoding) return;
    setState(() => _decoding = true);
    try {
      final PickedPicture? picked;
      try {
        picked = await Scanner.pickAndScan();
      } on UnreadableImage {
        if (mounted) _say('That file is not a picture this device can read');
        return;
      }
      // Aliased so the closure below can see it as non-null: a final assigned
      // inside a try is not promoted into one.
      if (!mounted || picked == null) return;
      final found = picked.outcome;
      if (found.results.isEmpty) {
        // Two different failures, and they call for two different things from
        // the reader. A candidate with no result means the detector saw a
        // symbol and the decoder could not read it — too small in the frame,
        // or too blurred — which is worth saying rather than claiming there
        // was nothing there.
        _say(
          found.candidates.isEmpty
              ? 'No QR code found in that picture'
              : 'A code was spotted but could not be read — it may be too small '
                    'in the picture, or too blurred',
        );
        return;
      }
      // Several codes in one picture: the reader has to say which, and can
      // only say it while looking at the picture. Same as the camera, which
      // freezes its frame for the same reason.
      var results = found.results;
      if (results.length > 1) {
        final image = await picked.file.readAsBytes();
        if (!mounted) return;
        final chosen = await Navigator.of(context).push<ScanResult>(
          MaterialPageRoute<ScanResult>(
            builder: (_) => PickPage(image: image, outcome: found),
          ),
        );
        if (!mounted || chosen == null) return;
        results = [chosen];
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ResultPage(results: results)),
      );
    } finally {
      if (mounted) setState(() => _decoding = false);
    }
  }

  void _say(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        // Held to a phone's measure and centred, so a desktop window shows the
        // same screen rather than three entries stretched across a metre.
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            // The way to the about screen is pinned to the foot of the
            // screen rather than trailing the content, so it reads as the end
            // of the page wherever the content happens to stop. What is above
            // it scrolls; it does not.
            child: Column(
              children: [
                Expanded(child: _entries(theme)),
                // Named rather than an icon in the corner. An icon on its own
                // says nothing about where it goes, and this is where a reader
                // who has just seen what the application does looks for what
                // it is and where it came from.
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AboutPage(),
                      ),
                    ),
                    icon: const Icon(Icons.info_outline, size: 18),
                    label: const Text('About wxscan and its source'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Everything above the foot of the page, and the only part that scrolls.
  Widget _entries(ThemeData theme) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 32, 20, 8),
    children: [
      Text('wxscan', style: theme.textTheme.displaySmall),
      const SizedBox(height: 8),
      Text(
        'QR scanning that reads the codes other scanners give up on: '
        'a neural network finds the symbol, a second one sharpens it, '
        'and nothing leaves this device.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 28),
      _Entry(
        icon: Icons.qr_code_scanner,
        title: 'Live scan',
        subtitle:
            'Point the camera at a code. Several in one frame '
            'come back together, and you pick.',
        onTap: _openScanner,
      ),
      const SizedBox(height: 12),
      _Entry(
        icon: Icons.photo_library_outlined,
        title: 'Decode a picture',
        subtitle:
            'A screenshot or a photo from the library, read '
            'without the camera.',
        onTap: _decodeAPicture,
        busy: _decoding,
      ),
      const SizedBox(height: 28),
      _engineLine(theme),
    ],
  );

  /// Which engine the weights left us with. Worth saying plainly: it is the
  /// difference between reading a code across a room and needing it held up to
  /// the lens, and a reader who sees the second one deserves to know why.
  ///
  /// Without them it is not a line but a panel, because it is the one state
  /// here that the reader can do something about, and because a copy of this
  /// example fetched from pub.dev starts in it: the weights are not in the
  /// published package. A grey line under two cards is how that goes unread
  /// until someone concludes the scanner is bad.
  Widget _engineLine(ThemeData theme) {
    if (_nnEnabled == false) return _weightsMissing(theme);
    final (icon, text) = switch (_nnEnabled) {
      null => (Icons.hourglass_empty, 'Loading the weights'),
      _ => (Icons.memory, 'CNN detection and super resolution'),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  /// Said in full: what is running, what it costs, and what to do about it.
  Widget _weightsMissing(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_outlined, size: 18, color: scheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Running without the weights',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'Image processing only, so small and distant codes will be '
                  'missed. Codes held up to the lens still read.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (Scanner.weightsProblem case final why?) ...[
                  const SizedBox(height: 8),
                  Text(
                    why,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One thing the application can do.
class _Entry extends StatelessWidget {
  const _Entry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: busy
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(icon, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
