/// Picking one code out of several found in a picture from the library.
///
/// The camera does this without a page of its own: it already has the picture
/// on screen and only has to stop moving. A picture from the library has never
/// been shown at all, so it is shown here — the same markers over the same
/// image the codes were read from, which is the only way a reader can tell
/// which of several codes is which.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:wxscan/wxscan.dart';

import 'pick_overlay.dart';

class PickPage extends StatelessWidget {
  const PickPage({super.key, required this.image, required this.outcome});

  /// The picture as it was read, encoded — PNG, JPEG, HEIC, whatever the
  /// library handed over.
  final Uint8List image;

  /// What was found in it. Only [ScanOutcome.results] are markable; a
  /// candidate nothing could be read from has nothing to open.
  final ScanOutcome outcome;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${outcome.results.length} codes in this picture'),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final box = Size(constraints.maxWidth, constraints.maxHeight);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                final hit =
                    pickHitTest(d.localPosition, BoxFit.contain, box, outcome);
                if (hit != null) Navigator.of(context).pop(hit);
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Contained, not covered: a picture the reader chose is
                  // theirs to see whole, and cropping it would hide a code
                  // that is being offered.
                  Image.memory(image, fit: BoxFit.contain),
                  CustomPaint(
                    size: Size.infinite,
                    painter:
                        PickPainter(frame: outcome, fit: BoxFit.contain),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      bottomNavigationBar: const SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Text(
            'Tap a marker to open that code',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
        ),
      ),
    );
  }
}
