import 'package:flutter/material.dart';

/// A 7-segment number readout, like the Sidekick's BPM display. Filled,
/// slightly slanted segments; digits, '.', '-' and '—' (shown as a dash).
class SevenSegmentText extends StatelessWidget {
  const SevenSegmentText(
    this.text, {
    super.key,
    required this.color,
    required this.height,
  });

  final String text;
  final Color color;
  /// Digit height in logical pixels.
  final double height;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(SevenSegmentPainter.widthFor(text, height), height),
      painter: SevenSegmentPainter(text, color),
    );
  }
}

class SevenSegmentPainter extends CustomPainter {
  SevenSegmentPainter(this.text, this.color);

  final String text;
  final Color color;

  static const _digits = {
    '0': 'abcdef',
    '1': 'bc',
    '2': 'abged',
    '3': 'abgcd',
    '4': 'fgbc',
    '5': 'afgcd',
    '6': 'afgedc',
    '7': 'abc',
    '8': 'abcdefg',
    '9': 'abcfgd',
    '-': 'g',
    '—': 'g',
    ' ': '',
  };

  static const _width = 0.54; // digit width / height
  static const _gap = 0.2; // gap / height
  static const _thick = 0.16; // segment thickness / height
  static const _slant = 0.1; // horizontal lean over the full height

  static double widthFor(String text, double h) {
    var w = 0.0;
    var digits = 0;
    for (final ch in text.split('')) {
      if (ch == '.') {
        w += h * _thick * 1.4;
      } else {
        if (digits > 0) w += h * _gap;
        w += h * _width;
        digits++;
      }
    }
    return w + h * _slant;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final w = h * _width;
    final th = h * _thick;
    final t = th / 2;
    final m = th * 0.22; // gap where segments meet
    final hh = h / 2;
    final paint = Paint()..color = color;
    canvas.save();
    // Lean the digits: x moves by slant * (h - y), so the tops lean right.
    canvas.translate(h * _slant, 0);
    canvas.skew(-_slant, 0);
    var x = 0.0;
    var digits = 0;
    for (final ch in text.split('')) {
      if (ch == '.') {
        canvas.drawRect(Rect.fromLTWH(x - h * _gap * 0.35, h - th, th, th), paint);
        x += h * _thick * 1.4;
        continue;
      }
      if (digits > 0) x += h * _gap;
      digits++;
      final segs = _digits[ch] ?? '';
      final path = Path();
      void horiz(double y) => path.addPolygon([
            Offset(x + t + m, y),
            Offset(x + th + m, y - t),
            Offset(x + w - th - m, y - t),
            Offset(x + w - t - m, y),
            Offset(x + w - th - m, y + t),
            Offset(x + th + m, y + t),
          ], true);
      void vert(double cx, double y0, double y1) => path.addPolygon([
            Offset(cx, y0),
            Offset(cx + t, y0 + t),
            Offset(cx + t, y1 - t),
            Offset(cx, y1),
            Offset(cx - t, y1 - t),
            Offset(cx - t, y0 + t),
          ], true);
      if (segs.contains('a')) horiz(t);
      if (segs.contains('g')) horiz(hh);
      if (segs.contains('d')) horiz(h - t);
      if (segs.contains('f')) vert(x + t, t + m, hh - m);
      if (segs.contains('b')) vert(x + w - t, t + m, hh - m);
      if (segs.contains('e')) vert(x + t, hh + m, h - t - m);
      if (segs.contains('c')) vert(x + w - t, hh + m, h - t - m);
      canvas.drawPath(path, paint);
      x += w;
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant SevenSegmentPainter old) =>
      old.text != text || old.color != color;
}
