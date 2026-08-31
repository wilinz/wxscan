/// Picking one code out of several, shared by the two paths that need it.
///
/// The camera freezes the frame it scanned and draws this over the preview;
/// the library path draws it over the picture that was chosen. The geometry is
/// the same problem in both — an image laid into a box, and markers that have
/// to land where the codes actually are — and the only difference is how the
/// image was fitted, which is why that is a parameter rather than two copies
/// of the mapping.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wxscan_live/wxscan_live.dart';

/// Radius of a marker, which is also the basis for tap hit-testing: the
/// tolerance is twice this.
const double kPickRadius = 22;

/// Where an image of [w] by [h] lands inside [box], fitted the given way.
///
/// Drawing and hit-testing have to share one of these, or the markers drawn
/// and the places that can actually be tapped drift apart.
({double scale, double dx, double dy}) pickFit(
  BoxFit fit,
  Size box,
  int w,
  int h,
) {
  final scale = fit == BoxFit.cover
      ? math.max(box.width / w, box.height / h)
      : math.min(box.width / w, box.height / h);
  return (
    scale: scale,
    dx: (box.width - w * scale) / 2,
    dy: (box.height - h * scale) / 2,
  );
}

/// The centre of a code, in the box's coordinates.
Offset pickCenter(ScanResult r, BoxFit fit, Size box, ScanOutcome f) {
  final m = pickFit(fit, box, f.width, f.height);
  final c = r.corners.centre;
  return Offset(c.dx * m.scale + m.dx, c.dy * m.scale + m.dy);
}

/// The code nearest the tap; beyond the tolerance it counts as a miss.
ScanResult? pickHitTest(Offset tap, BoxFit fit, Size box, ScanOutcome frame) {
  ScanResult? best;
  var bestDist = double.infinity;
  for (final r in frame.results) {
    if (r.corners.isEmpty) continue;
    final d = (pickCenter(r, fit, box, frame) - tap).distance;
    if (d < bestDist) {
      bestDist = d;
      best = r;
    }
  }
  return bestDist <= kPickRadius * 2 ? best : null;
}

/// Darkens the picture and puts a marker with an arrow on each code.
class PickPainter extends CustomPainter {
  const PickPainter({required this.frame, required this.fit});

  final ScanOutcome frame;

  /// How the image underneath was laid into the same box.
  final BoxFit fit;

  static const _green = Color(0xFF07C160);

  @override
  void paint(Canvas canvas, Size size) {
    if (frame.width == 0 || frame.height == 0) return;

    // Darken everything so the markers stand out.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black.withValues(alpha: 0.5),
    );

    final m = pickFit(fit, size, frame.width, frame.height);
    Offset at(ScanPoint p) =>
        Offset(p.dx * m.scale + m.dx, p.dy * m.scale + m.dy);

    for (final r in frame.results) {
      if (r.corners.isEmpty) continue;

      // Outline where the code actually is, then put the button at its
      // centre. The two share one mapping, which makes a misplacement obvious
      // at a glance.
      final path = Path();
      for (var i = 0; i < r.corners.length; i++) {
        final p = at(r.corners[i]);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      path.close();
      canvas.drawPath(path, Paint()..color = _green.withValues(alpha: 0.18));
      canvas.drawPath(
        path,
        Paint()
          ..color = _green
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );

      final c = pickCenter(r, fit, size, frame);
      canvas.drawCircle(
        c,
        kPickRadius + 6,
        Paint()..color = _green.withValues(alpha: 0.25),
      );
      canvas.drawCircle(c, kPickRadius, Paint()..color = _green);

      // A white arrow pointing right.
      final arrow = Paint()
        ..color = Colors.white
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      canvas.drawLine(c.translate(-4, -7), c.translate(4, 0), arrow);
      canvas.drawLine(c.translate(4, 0), c.translate(-4, 7), arrow);
    }
  }

  @override
  bool shouldRepaint(PickPainter old) => old.frame != frame || old.fit != fit;
}
