import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wxscan_live/wxscan_live.dart';

/// Result page: the decoded text plus its metadata (version, error
/// correction level, charset).
class ResultPage extends StatelessWidget {
  final List<ScanResult> results;

  const ResultPage({super.key, required this.results});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(results.length > 1 ? 'Results (${results.length})' : 'Result'),
      ),
      // Held to a readable measure: a decoded URL stretched across a desktop
      // window is one long line the eye cannot get back from.
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: results.length,
            separatorBuilder: (context, index) => const SizedBox(height: 12),
            itemBuilder: (context, i) => _ResultCard(result: results[i]),
          ),
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final ScanResult result;

  const _ResultCard({required this.result});

  bool get _isUrl {
    final t = result.text.trim();
    return t.startsWith('http://') || t.startsWith('https://');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _isUrl ? Icons.link : Icons.text_snippet_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  _isUrl ? 'Link' : 'Text',
                  style: theme.textTheme.labelLarge,
                ),
              ],
            ),
            const SizedBox(height: 12),
            SelectableText(
              result.text,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Chip(label: 'Version ${result.version}'),
                if (result.ecLevel.isNotEmpty) _Chip(label: 'EC ${result.ecLevel}'),
                _Chip(label: result.charset),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: result.text));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Copied')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;

  const _Chip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}
