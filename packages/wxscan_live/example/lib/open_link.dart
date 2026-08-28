/// Handing an address to the platform, and saying so when it refuses.
///
/// Its own file because two screens need it and neither owns it: the about
/// screen opens the addresses it lists, and the result screen opens a code
/// that turned out to be a link.
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [url] in whatever the platform hands links to.
///
/// A refusal is reported rather than swallowed. A device with nothing
/// registered for http, a malformed address inside a QR code, or a browser
/// that blocked the tab otherwise looks exactly like a button that does
/// nothing — and a code containing a link that will not open is worth knowing
/// about, since it is the kind of thing a reader would blame the scanner for.
Future<void> openLink(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.of(context);
  var opened = false;
  try {
    opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  } on Object {
    opened = false;
  }
  if (!opened) {
    messenger.showSnackBar(SnackBar(content: Text('Could not open $url')));
  }
}
