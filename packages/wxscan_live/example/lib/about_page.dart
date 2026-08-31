/// What this application is, and where the parts of it live.
///
/// An example is read as much as it is run, and a reader who has just watched
/// a code decode wants to know what did the decoding and where to get it. The
/// addresses are here rather than buried in a README nobody opens from a
/// phone.
library;

import 'package:flutter/material.dart';

import 'open_link.dart';

/// Somewhere to go, with a line saying why it is worth going.
typedef _Link = ({IconData icon, String title, String subtitle, String url});

const _links = <_Link>[
  (
    icon: Icons.code,
    title: 'wilinz/wxscan',
    subtitle: 'The source of both packages, this example included',
    url: 'https://github.com/wilinz/wxscan',
  ),
  (
    icon: Icons.terminal,
    title: 'wilinz/wxscan-rs',
    subtitle: 'The Rust decoder underneath, built as a code asset',
    url: 'https://github.com/wilinz/wxscan-rs',
  ),
  (
    icon: Icons.memory,
    title: 'wilinz/wxscan-weights',
    subtitle: 'The two CNN models, and how they were converted',
    url: 'https://github.com/wilinz/wxscan-weights',
  ),
  (
    icon: Icons.public,
    title: 'Live demo',
    subtitle: 'This application in a browser, decoding in a worker',
    url: 'https://wilinz.github.io/wxscan/',
  ),
  (
    icon: Icons.bug_report_outlined,
    title: 'Issues',
    subtitle: 'A code that will not read is worth a picture and a report',
    url: 'https://github.com/wilinz/wxscan/issues',
  ),
];

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            children: [
              Text('wxscan', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                'A QR scanner for Flutter that reads the codes other scanners '
                'give up on. A neural network finds the symbol, a second one '
                'sharpens it before decoding, and both run on the device — no '
                'picture and no decoded text ever leaves it.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Two packages: wxscan decodes a picture, wxscan_live drives the '
                'camera. This screen is part of the example for the second, and '
                'is meant to be read as much as run.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              for (final link in _links) ...[
                _LinkTile(link: link),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({required this.link});

  final _Link link;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(link.icon, color: theme.colorScheme.primary),
        title: Text(link.title),
        subtitle: Text(link.subtitle),
        trailing: Icon(
          Icons.open_in_new,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        onTap: () => openLink(context, link.url),
      ),
    );
  }
}
