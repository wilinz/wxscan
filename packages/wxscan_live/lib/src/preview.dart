/// The camera preview, on whichever platform.
///
/// Native builds render a texture the camera writes into. A browser has no
/// such thing: the frames are already in a `<video>` element, and the way to
/// put one on screen is a platform view. This is the surface either way, and
/// nothing else — like [Texture], which it stands in for, it draws the image
/// upright in the device's natural orientation and leaves rotating and sizing
/// to whatever composes it. [WxPreviewSize] says how far to turn.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import '../wxscan_live.dart';

/// The view type the browser preview is registered under.
///
/// Named here rather than beside the web implementation so that the widget and
/// that implementation can both refer to it without importing each other.
const wxScanPreviewViewType = 'wxscan_live/preview';

/// The live camera image.
///
/// ```dart
/// WxScanPreview(controller: controller)
/// ```
///
/// It listens to the controller, so it appears when the camera opens and
/// follows a rotation without anything else being wired up. Before the camera
/// is open it is an empty box rather than an error, which is what a screen
/// wants while it is starting.
///
/// This is the image and nothing else. Everything a scanning screen puts over
/// it — the viewfinder, the corners drawn on each decoded code, picking among
/// several in one frame, and the cover-fit mapping that takes frame
/// coordinates to screen coordinates so that drawing and tapping agree — is an
/// application's to write, and `example/lib/scan_page.dart` in this package is
/// a complete one to read or copy. It is also what the
/// [live demo](https://wilinz.github.io/wxscan/) is running.
class WxScanPreview extends StatelessWidget {
  const WxScanPreview({super.key, required this.controller});

  /// The camera to show.
  final WxScanController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<WxScanValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          if (!value.isInitialized) return const SizedBox.shrink();
          return kIsWeb
              // The browser's frames are in a <video> the platform view holds,
              // so there is no texture id to give and nothing to rebuild on.
              ? const HtmlElementView(viewType: wxScanPreviewViewType)
              : Texture(textureId: value.textureId);
        },
      );
}
