import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sidedeck/state/ui_settings.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Horizontal scrolling DJ waveform: playhead pinned center, regular beat grid.
class WaveformPainter extends CustomPainter {
  WaveformPainter({
    required this.min,
    required this.max,
    required this.position,
    required this.duration,
    required this.beatOffset,
    required this.bpm,
    required this.color,
    required this.peak,
    required this.palette,
    this.style = WaveStyle.solid,
    this.binSec = 0,
    Float32List? tone,
    Float32List? overviewBands,
    this.rate = 1,
    this.loopEnabled = false,
    this.loopStart = 0,
    this.loopEnd = 0,
    this.zoomWindowSec = 8,
    this.showJumpZone = false,
  }) : tone = tone ?? Float32List(0),
       overviewBands = overviewBands ?? Float32List(0);

  final Float32List min;
  final Float32List max;
  final double position;
  final double duration;
  final double beatOffset;
  final double bpm;
  final Color color;
  /// Max abs amplitude across [min]/[max]; computed once when the wave data changes.
  final double peak;
  final SideDeckColors palette;
  final WaveStyle style;
  /// Seconds of audio per bin of [min]/[max]/[tone]; 0: spread over [duration].
  final double binSec;
  /// Per waveform bin, 0..1: how bass-heavy it is compared with the rest of
  /// the track. Lights the waveform where the kicks are. Empty: by loudness.
  final Float32List tone;
  /// Overview columns on a 3 px pitch, three values each (low, mid, high),
  /// 0..1 against this track's own range. Empty: peaks, as before.
  final Float32List overviewBands;
  /// Playback rate (file seconds per heard second). Zooms the scrolling
  /// waveform in heard-time so synced decks share a beat grid.
  final double rate;
  final bool loopEnabled;
  final double loopStart;
  final double loopEnd;
  final double zoomWindowSec;
  final bool showJumpZone;

  /// Share of the lane a full-scale waveform fills, top to bottom.
  static const waveHeight = 0.70;
  static const overviewH = 24.0;
  static const jumpHalf = 0.14;
  static const _cell = 12.0;

  /// Left edge of the beat-jump hit rect; same math as [_drawJumpZone].
  static double jumpZoneLeft(double width) => width * (0.5 - jumpHalf);

  /// Right edge of the beat-jump hit rect.
  static double jumpZoneRight(double width) => width * (0.5 + jumpHalf);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.screen);
    if (size.width <= 1 || size.height <= 1) {
      return;
    }
    // The cell grid is part of the glass: there with or without a track.
    _drawCells(canvas, Rect.fromLTWH(0, overviewH, size.width, size.height - overviewH));
    if (min.isEmpty || duration <= 0) {
      _drawEmptyStrip(canvas, size);
      return;
    }

    final n = math.min(min.length, max.length);
    const waveTop = overviewH;
    final waveH = size.height - overviewH;
    final mid = waveTop + waveH / 2;

    final playRate = rate.clamp(0.5, 2.0);
    // Heard-time window (what you hear), mapped back to file seconds.
    // rate > 1 compresses the wave; rate < 1 stretches it.
    final halfWin = (zoomWindowSec / 2) * playRate;
    final viewStart = position - halfWin;
    final viewEnd = position + halfWin;
    final viewDur = zoomWindowSec * playRate;

    double xForTime(double t) => ((t - viewStart) / viewDur) * size.width;

    _drawOverview(canvas, size, n, viewStart, viewEnd);

    final half = waveH * waveHeight / 2;
    final pxPerSec = size.width / viewDur;
    switch (style) {
      case WaveStyle.solid:
        _drawSolid(canvas, _slices(n, viewStart, viewEnd, pxPerSec, 1.0), mid, half, waveH);
      case WaveStyle.dots:
        _drawDots(canvas, _slices(n, viewStart, viewEnd, pxPerSec, 4.0), mid, half);
      case WaveStyle.curve:
        _drawCurve(canvas, _slices(n, viewStart, viewEnd, pxPerSec, 1.5), mid, half);
    }

    // Grid on top of the wave so it stays visible.
    _drawGrid(canvas, size, waveTop, viewStart, viewEnd, xForTime);
    _drawLoopZoomed(canvas, size, waveTop, xForTime);

    if (showJumpZone) {
      _drawJumpZone(canvas, size, waveTop);
    }

    _drawPlayhead(
      canvas,
      x: size.width / 2,
      y0: waveTop,
      y1: size.height,
      coreWidth: 2.6,
    );
    _marker(canvas, size.width / 2, waveTop, 6, 8);
  }

  /// Cuts the view into equal slices of a beat, about [targetPx] wide, the
  /// first starting on a grid line. Every beat is then drawn from the same
  /// stretch of its audio, so a repetitive track looks alike bar after bar
  /// and a slice keeps its shape while it scrolls. Without a grid: fixed
  /// slices from the start of the track.
  _Slices _slices(int n, double viewStart, double viewEnd, double pxPerSec, double targetPx) {
    final double origin, step;
    if (bpm > 1) {
      final beat = 60.0 / bpm;
      final perBeat = math.max(1, (beat * pxPerSec / targetPx).round());
      origin = beatOffset;
      step = beat / perBeat;
    } else {
      origin = 0;
      step = targetPx / pxPerSec;
    }
    final bin = binSec > 0 ? binSec : duration / n;
    final k0 = ((viewStart - origin) / step).floor();
    final k1 = ((viewEnd - origin) / step).ceil();
    final out = _Slices(k1 - k0 + 1);
    for (var k = k0; k <= k1; k++) {
      final t0 = origin + k * step;
      final t1 = t0 + step;
      if (t1 <= 0 || t0 >= duration) continue;
      // The bins whose centres fall in the slice; a slice narrower than a
      // bin takes the nearest one.
      var i0 = (t0 / bin - 0.5).ceil();
      var i1 = (t1 / bin - 0.5).ceil() - 1;
      if (i1 < i0) i0 = i1 = ((t0 + t1) / 2 / bin).floor();
      i0 = i0.clamp(0, n - 1);
      i1 = i1.clamp(0, n - 1);
      var lo = 0.0, hi = 0.0, lit = -1.0;
      for (var i = i0; i <= i1; i++) {
        lo = math.min(lo, min[i]);
        hi = math.max(hi, max[i]);
        if (i < tone.length && tone[i] > lit) lit = tone[i];
      }
      out.add((t0 - viewStart) * pxPerSec, step * pxPerSec, hi / peak, -lo / peak, lit);
    }
    return out;
  }

  /// Deck colour lit by the low band: kicks and bass full, the rest dimmed.
  /// Falls back to loudness when there is no tone data.
  Color _shade(Color base, double amp, double toneValue) {
    if (toneValue < 0) return _ampColor(base, amp);
    return base.withValues(alpha: 0.3 + 0.7 * toneValue);
  }

  /// Vertical lines in the deck colour, one per slice.
  void _drawSolid(Canvas canvas, _Slices s, double mid, double half, double waveH) {
    final paint = Paint();
    for (var i = 0; i < s.length; i++) {
      final yHi = mid - s.up[i] * half;
      final yLo = mid + s.down[i] * half;
      paint.color = _shade(color, math.max(s.up[i], s.down[i]), s.tone[i]);
      canvas.drawRect(
        Rect.fromLTWH(s.x[i], yHi, s.w[i] + 0.05, (yLo - yHi).clamp(1.0, waveH)),
        paint,
      );
    }
  }

  /// Lit cells on a 4 px pitch, like the Sidekick's dot-matrix screen.
  void _drawDots(Canvas canvas, _Slices s, double mid, double half) {
    const pitch = 4.0;
    const levels = 6;
    if (s.length == 0) return;
    final rows = (half / pitch).floor();
    final points = List.generate(levels, (_) => <double>[]);
    for (var i = 0; i < s.length; i++) {
      final t = s.tone[i];
      final level = t < 0 ? levels - 1 : (t * (levels - 1)).round();
      final up = math.min(rows, (s.up[i] * half / pitch).round());
      final down = math.min(rows, (s.down[i] * half / pitch).round());
      final cx = s.x[i] + s.w[i] / 2;
      final out = points[level];
      for (var r = 0; r < up; r++) {
        out
          ..add(cx)
          ..add(mid - (r + 0.5) * pitch);
      }
      for (var r = 0; r < down; r++) {
        out
          ..add(cx)
          ..add(mid + (r + 0.5) * pitch);
      }
    }
    // Slices are a whole fraction of a beat, so about (not exactly) 4 px.
    final paint = Paint()
      ..strokeWidth = (s.w[0] - 1).clamp(1.0, pitch - 1)
      ..strokeCap = StrokeCap.square;
    for (var l = 0; l < levels; l++) {
      if (points[l].isEmpty) continue;
      paint.color = color.withValues(alpha: 0.3 + 0.7 * l / (levels - 1));
      canvas.drawRawPoints(PointMode.points, Float32List.fromList(points[l]), paint);
    }
  }

  /// Filled body with a line along the peaks, like the Sidekick's EQ graph.
  /// The body glows where the low band is strong.
  void _drawCurve(Canvas canvas, _Slices s, double mid, double half) {
    final n = s.length;
    if (n == 0) return;
    final up = _smooth(Float64List.sublistView(s.up, 0, n));
    final down = _smooth(Float64List.sublistView(s.down, 0, n));
    final body = Paint();
    for (var i = 0; i < n; i++) {
      if (up[i] <= 0 && down[i] <= 0) continue;
      final t = s.tone[i];
      body.color = palette.waveBody.withValues(alpha: t < 0 ? 1.0 : 0.35 + 0.65 * t);
      canvas.drawRect(
        Rect.fromLTRB(s.x[i], mid - up[i] * half, s.x[i] + s.w[i] + 0.05, mid + down[i] * half),
        body,
      );
    }
    final edge = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeJoin = StrokeJoin.round;
    final upper = Path();
    final lower = Path();
    for (var i = 0; i < n; i++) {
      final cx = s.x[i] + s.w[i] / 2;
      if (i == 0) {
        upper.moveTo(cx, mid - up[i] * half);
        lower.moveTo(cx, mid + down[i] * half);
      } else {
        upper.lineTo(cx, mid - up[i] * half);
        lower.lineTo(cx, mid + down[i] * half);
      }
    }
    canvas.drawPath(upper, edge);
    canvas.drawPath(lower, edge);
  }

  static Float64List _smooth(Float64List a) {
    final out = Float64List(a.length);
    for (var i = 0; i < a.length; i++) {
      final prev = a[i == 0 ? 0 : i - 1];
      final next = a[i == a.length - 1 ? i : i + 1];
      out[i] = (prev + 2 * a[i] + next) / 4;
    }
    return out;
  }

  /// The overview strip of an empty deck: band and rules, no track.
  void _drawEmptyStrip(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, overviewH),
      Paint()..color = palette.stripBg,
    );
    final rule = Paint()..color = palette.lit.withValues(alpha: 0.5);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, 1), rule);
    canvas.drawRect(Rect.fromLTWH(0, overviewH - 1, size.width, 1), rule);
  }

  /// The still cell grid of the Sidekick screen, behind everything.
  void _drawCells(Canvas canvas, Rect r) {
    final p = Paint()
      ..color = palette.cellGrid
      ..strokeWidth = 1;
    for (var x = r.left + (r.width % _cell) / 2; x <= r.right; x += _cell) {
      canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), p);
    }
    for (var y = r.top + (r.height % _cell) / 2; y <= r.bottom; y += _cell) {
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), p);
    }
  }

  /// Whole track in a black strip between two orange rules, like the strips
  /// on the Sidekick's LOOP and SIREN screens.
  void _drawOverview(Canvas canvas, Size size, int n, double viewStart, double viewEnd) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, overviewH),
      Paint()..color = palette.stripBg,
    );
    final cols = overviewBands.length ~/ 3;
    if (cols > 0) {
      // Three bands stacked: low (bone) carries the kicks and bass, so drops
      // stand tall and breakdowns shrink to their mids and highs.
      const avail = overviewH - 4;
      final low = Paint()..color = palette.text;
      final midP = Paint()..color = palette.muted;
      final high = Paint()..color = palette.played;
      final pitch = size.width / cols;
      for (var c = 0; c < cols; c++) {
        final x = c * pitch;
        var y = overviewH - 2;
        final lh = overviewBands[c * 3] * avail * 0.5;
        final mh = overviewBands[c * 3 + 1] * avail * 0.3;
        final hh = overviewBands[c * 3 + 2] * avail * 0.2;
        if (lh > 0) canvas.drawRect(Rect.fromLTWH(x, y - lh, pitch * 0.7, lh), low);
        y -= lh;
        if (mh > 0) canvas.drawRect(Rect.fromLTWH(x, y - mh, pitch * 0.7, mh), midP);
        y -= mh;
        if (hh > 0) canvas.drawRect(Rect.fromLTWH(x, y - hh, pitch * 0.7, hh), high);
      }
    } else {
      final bars = Paint()..color = palette.stripBars;
      for (var px = 0.0; px < size.width; px += 3) {
        final t0 = (px / size.width) * duration;
        final t1 = ((px + 3) / size.width) * duration;
        final amp = _peakInRange(t0, t1, n, duration, peak).clamp(0.0, 1.0);
        final h = math.max(1.0, amp * (overviewH - 6));
        canvas.drawRect(Rect.fromLTWH(px, overviewH - 2 - h, 2, h), bars);
      }
    }
    final winL = ((viewStart / duration) * size.width).clamp(0.0, size.width);
    final winR = ((viewEnd / duration) * size.width).clamp(0.0, size.width);
    canvas.drawRect(
      Rect.fromLTRB(winL, 1, winR, overviewH - 1),
      Paint()..color = palette.text.withValues(alpha: 0.13),
    );
    _drawLoopOverview(canvas, size);
    final rule = Paint()..color = palette.lit;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, 1), rule);
    canvas.drawRect(Rect.fromLTWH(0, overviewH - 1, size.width, 1), rule);
    final x = (position / duration) * size.width;
    canvas.drawRect(
      Rect.fromLTWH(x - 0.6, 1, 1.2, overviewH - 2),
      Paint()..color = palette.playhead,
    );
    _marker(canvas, x, 1, 4.5, 6, outline: false);
  }

  /// Grey line on every beat; orange on beat 1 of each 4-beat bar; thicker
  /// orange with flags every 8 bars.
  void _drawGrid(
    Canvas canvas,
    Size size,
    double waveTop,
    double viewStart,
    double viewEnd,
    double Function(double) xForTime,
  ) {
    final beatSec = bpm > 1 ? 60.0 / bpm : 0.0;
    if (beatSec <= 0.05) return;
    final beat = Paint()
      ..color = palette.beatLine
      ..strokeWidth = 1.2;
    final halo = Paint()..color = palette.halo.withValues(alpha: 0.5);
    final bar = Paint()..color = palette.lit.withValues(alpha: 0.75);
    var t = beatOffset;
    if (t > viewStart) {
      t -= (((t - viewStart) / beatSec).ceil() * beatSec);
    }
    while (t < viewStart) {
      t += beatSec;
    }
    for (; t <= viewEnd; t += beatSec) {
      if (t < 0 || t > duration) continue;
      final idx = ((t - beatOffset) / beatSec).round();
      final x = xForTime(t);
      if (idx % 4 != 0) {
        canvas.drawLine(Offset(x, waveTop), Offset(x, size.height), beat);
        continue;
      }
      final phrase = idx % 32 == 0; // 8 bars
      final w = phrase ? 2.4 : 1.5;
      halo.strokeWidth = w + 1.5;
      bar.strokeWidth = w;
      canvas.drawLine(Offset(x, waveTop), Offset(x, size.height), halo);
      canvas.drawLine(Offset(x, waveTop), Offset(x, size.height), bar);
      if (phrase) {
        canvas.drawRect(Rect.fromLTWH(x - 3.5, waveTop, 7, 5), bar);
        canvas.drawRect(Rect.fromLTWH(x - 3.5, size.height - 5, 7, 5), bar);
      }
    }
  }

  void _drawPlayhead(
    Canvas canvas, {
    required double x,
    required double y0,
    required double y1,
    required double coreWidth,
  }) {
    final halo = Paint()
      ..color = palette.halo
      ..strokeWidth = coreWidth + 2.4
      ..strokeCap = StrokeCap.square;
    final core = Paint()
      ..color = palette.playhead
      ..strokeWidth = coreWidth
      ..strokeCap = StrokeCap.square;
    canvas.drawLine(Offset(x, y0), Offset(x, y1), halo);
    canvas.drawLine(Offset(x, y0), Offset(x, y1), core);
  }

  /// The Sidekick's orange ▼ position marker.
  void _marker(Canvas canvas, double x, double top, double hw, double h, {bool outline = true}) {
    if (outline) {
      final o = Path()
        ..moveTo(x - hw - 1.5, top)
        ..lineTo(x + hw + 1.5, top)
        ..lineTo(x, top + h + 2)
        ..close();
      canvas.drawPath(o, Paint()..color = palette.halo);
    }
    final p = Path()
      ..moveTo(x - hw, top)
      ..lineTo(x + hw, top)
      ..lineTo(x, top + h)
      ..close();
    canvas.drawPath(p, Paint()..color = palette.lit);
  }

  void _drawJumpZone(Canvas canvas, Size size, double waveTop) {
    final cx = size.width / 2;
    final half = size.width * jumpHalf;
    final left = cx - half;
    final right = cx + half;
    canvas.drawRect(
      Rect.fromLTRB(left, waveTop, right, size.height),
      Paint()..color = palette.text.withValues(alpha: 0.03),
    );
    final edge = Paint()
      ..color = palette.text.withValues(alpha: 0.12)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(left, waveTop), Offset(left, size.height), edge);
    canvas.drawLine(Offset(right, waveTop), Offset(right, size.height), edge);

    final cy = waveTop + (size.height - waveTop) / 2;
    _chevron(canvas, Offset(cx - half * 0.55, cy), left: true);
    _chevron(canvas, Offset(cx + half * 0.55, cy), left: false);
    _jumpLabel(canvas, Offset(cx - half * 0.55 + 10, cy - 7), '4');
    _jumpLabel(canvas, Offset(cx + half * 0.55 - 18, cy - 7), '4');
  }

  void _chevron(Canvas canvas, Offset c, {required bool left}) {
    final paint = Paint()
      ..color = palette.text.withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round;
    final dx = left ? -6.0 : 6.0;
    final path = Path()
      ..moveTo(c.dx - dx, c.dy - 8)
      ..lineTo(c.dx + dx, c.dy)
      ..lineTo(c.dx - dx, c.dy + 8);
    canvas.drawPath(path, paint);
  }

  void _jumpLabel(Canvas canvas, Offset o, String s) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: palette.text.withValues(alpha: 0.45),
          fontSize: 10,
          fontWeight: FontWeight.w700,
          fontFamily: SideDeckTheme.fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, o);
  }

  void _drawLoopOverview(Canvas canvas, Size size) {
    if (!loopEnabled || loopEnd <= loopStart || duration <= 0) return;
    final x0 = ((loopStart / duration) * size.width).clamp(0.0, size.width);
    final x1 = ((loopEnd / duration) * size.width).clamp(0.0, size.width);
    if (x1 <= x0) return;
    canvas.drawRect(
      Rect.fromLTRB(x0, 1, math.max(x1, x0 + 2), overviewH - 1),
      Paint()..color = palette.lit.withValues(alpha: 0.45),
    );
  }

  void _drawLoopZoomed(
    Canvas canvas,
    Size size,
    double waveTop,
    double Function(double) xForTime,
  ) {
    if (!loopEnabled || loopEnd <= loopStart) return;
    final x0 = xForTime(loopStart);
    final x1 = xForTime(loopEnd);
    if (x1 < 0 || x0 > size.width) return;
    final left = x0.clamp(0.0, size.width);
    final right = x1.clamp(0.0, size.width);
    canvas.drawRect(
      Rect.fromLTRB(left, waveTop, right, size.height),
      Paint()..color = palette.lit.withValues(alpha: 0.12),
    );
    final edge = Paint()
      ..color = palette.lit
      ..strokeWidth = 2;
    if (x0 >= 0 && x0 <= size.width) {
      canvas.drawLine(Offset(x0, waveTop), Offset(x0, size.height), edge);
    }
    if (x1 >= 0 && x1 <= size.width) {
      canvas.drawLine(Offset(x1, waveTop), Offset(x1, size.height), edge);
    }
  }

  (double, double) _minMaxInRange(double t0, double t1, int n, double duration) {
    var i0 = ((t0 / duration) * n).floor().clamp(0, n - 1);
    var i1 = ((t1 / duration) * n).ceil().clamp(0, n - 1);
    if (i1 < i0) i1 = i0;
    var lo = 0.0;
    var hi = 0.0;
    for (var i = i0; i <= i1; i++) {
      lo = math.min(lo, min[i]);
      hi = math.max(hi, max[i]);
    }
    return (lo, hi);
  }

  double _peakInRange(double t0, double t1, int n, double duration, double peak) {
    final mm = _minMaxInRange(t0, t1, n, duration);
    return math.max(mm.$1.abs(), mm.$2.abs()) / peak;
  }

  /// Deck colour, fainter for quiet passages.
  Color _ampColor(Color base, double amp) {
    final a = (amp / 0.75).clamp(0.0, 1.0);
    return base.withValues(alpha: 0.45 + 0.55 * a);
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.position != position ||
        oldDelegate.duration != duration ||
        oldDelegate.min != min ||
        oldDelegate.max != max ||
        oldDelegate.peak != peak ||
        oldDelegate.beatOffset != beatOffset ||
        oldDelegate.bpm != bpm ||
        oldDelegate.rate != rate ||
        oldDelegate.color != color ||
        oldDelegate.palette != palette ||
        oldDelegate.style != style ||
        oldDelegate.binSec != binSec ||
        oldDelegate.tone != tone ||
        oldDelegate.overviewBands != overviewBands ||
        oldDelegate.loopEnabled != loopEnabled ||
        oldDelegate.loopStart != loopStart ||
        oldDelegate.loopEnd != loopEnd ||
        oldDelegate.showJumpZone != showJumpZone;
  }
}

/// The scrolling view cut into slices: left edge and width (px), peaks above
/// and below the centre line (fractions of the track's peak), and tone
/// (0..1, or -1 without tone data).
class _Slices {
  _Slices(int capacity)
    : x = Float64List(capacity),
      w = Float64List(capacity),
      up = Float64List(capacity),
      down = Float64List(capacity),
      tone = Float64List(capacity);

  final Float64List x, w, up, down, tone;
  int length = 0;

  void add(double left, double width, double above, double below, double lit) {
    x[length] = left;
    w[length] = width;
    up[length] = above;
    down[length] = below;
    tone[length] = lit;
    length++;
  }
}

class WaveformView extends StatefulWidget {
  const WaveformView({
    super.key,
    required this.min,
    required this.max,
    required this.position,
    required this.duration,
    required this.color,
    this.binSec = 0,
    this.playing = false,
    this.beatOffset = 0,
    this.bpm = 0,
    this.rate = 1,
    this.scrollRate,
    this.style = WaveStyle.solid,
    this.low,
    this.mid,
    this.high,
    this.loopEnabled = false,
    this.loopStart = 0,
    this.loopEnd = 0,
    this.onSeek,
    this.onOverviewSeek,
  });

  final WaveStyle style;
  /// RMS per bin in the EQ's low / mid / high bands (from the engine).
  final Float32List? low;
  final Float32List? mid;
  final Float32List? high;
  final Float32List min;
  final Float32List max;
  /// Seconds of audio per bin of [min]/[max] and the bands (from the engine).
  final double binSec;
  final double position;
  final double duration;
  final bool playing;
  final double beatOffset;
  final double bpm;
  /// Deck tempo rate without the temporary nudge bend. Sets the zoom, so the
  /// beat grid keeps its size while you hold a nudge button.
  final double rate;
  /// Rate the playhead actually moves at, nudge included. Only drives the
  /// scrolling between engine position reports. Defaults to [rate].
  final double? scrollRate;
  final Color color;
  final bool loopEnabled;
  final double loopStart;
  final double loopEnd;
  /// Zoomed jump-zone tap (typically ±4 beat jump toward the tap).
  final ValueChanged<double>? onSeek;
  /// Full-track overview strip tap → absolute position in seconds.
  final ValueChanged<double>? onOverviewSeek;

  static const zoom = 8.0;

  @override
  State<WaveformView> createState() => _WaveformViewState();
}

class _WaveformViewState extends State<WaveformView>
    with SingleTickerProviderStateMixin {
  // Engine positions arrive ~every 50 ms; between reports, advance at [rate]
  // and ease out the residual so the wave doesn't hitch on each poll.
  late final Ticker _ticker = createTicker(_onFrame);
  double _base = 0;
  Duration _baseAt = Duration.zero;
  double _error = 0;
  double _shown = 0;
  Duration _now = Duration.zero;
  double _peak = 0.001;
  Float32List _tone = Float32List(0);
  // Bands per bin, 0..1 against this track's own range, and the overview
  // columns built from them for one width.
  Float32List _lowN = Float32List(0), _midN = Float32List(0), _highN = Float32List(0);
  Float32List _ovCols = Float32List(0);
  int _ovColsFor = -1;

  static const _snapSec = 0.25;
  static const _easeSec = 0.1;

  @override
  void initState() {
    super.initState();
    _base = _shown = widget.position;
    _refreshPeak();
    _refreshTone();
    _syncTicker();
  }

  @override
  void didUpdateWidget(WaveformView old) {
    super.didUpdateWidget(old);
    if (!identical(widget.min, old.min) || !identical(widget.max, old.max)) {
      _refreshPeak();
    }
    if (!identical(widget.low, old.low) ||
        !identical(widget.mid, old.mid) ||
        !identical(widget.high, old.high)) {
      _refreshTone();
    }
    // Re-base when the engine position jumps, transport starts/stops, or the
    // audible rate changes (BPM nudge / sync / pitch bend) so we don't keep
    // integrating an old rate over a long dt.
    if (widget.position != old.position ||
        widget.playing != old.playing ||
        _scrollRate(widget) != _scrollRate(old)) {
      final err = _shown - widget.position;
      _error = widget.playing && err.abs() < _snapSec ? err : 0;
      _base = widget.position;
      _baseAt = _now;
      if (!widget.playing) _shown = widget.position;
    }
    _syncTicker();
  }

  static double _scrollRate(WaveformView w) => w.scrollRate ?? w.rate;

  void _refreshPeak() {
    var peak = 0.001;
    final n = math.min(widget.min.length, widget.max.length);
    for (var i = 0; i < n; i++) {
      peak = math.max(peak, math.max(widget.min[i].abs(), widget.max[i].abs()));
    }
    _peak = peak;
  }

  /// Low-band share per bin, spread over this track's own range: the least
  /// bass-heavy fifth of its sound reads dim, the most bass-heavy twentieth
  /// full. So kicks light up whatever the genre or mastering.
  void _refreshTone() {
    final lo = widget.low, mi = widget.mid, hi = widget.high;
    _lowN = _midN = _highN = Float32List(0);
    _ovColsFor = -1;
    if (lo == null || mi == null || hi == null) {
      _tone = Float32List(0);
      return;
    }
    final n = math.min(lo.length, math.min(mi.length, hi.length));
    if (n == 0) {
      _tone = Float32List(0);
      return;
    }
    final share = Float32List(n);
    final sums = Float32List(n);
    var loudest = 0.0;
    for (var i = 0; i < n; i++) {
      final sum = lo[i] + mi[i] + hi[i];
      sums[i] = sum;
      share[i] = sum > 1e-9 ? lo[i] / sum : 0;
      if (sum > loudest) loudest = sum;
    }
    // Percentiles from every few bins: a long track has ~150k of them.
    final stride = math.max(1, n ~/ 30000);
    final sounding = <double>[
      for (var i = 0; i < n; i += stride)
        if (sums[i] > loudest * 0.05) share[i],
    ]..sort();
    if (sounding.length < 10) {
      _tone = Float32List(0);
      return;
    }
    final from = sounding[(sounding.length * 0.2).floor()];
    final to = sounding[math.min(sounding.length - 1, (sounding.length * 0.95).floor())];
    final span = math.max(1e-6, to - from);
    final tone = Float32List(n);
    for (var i = 0; i < n; i++) {
      tone[i] = ((share[i] - from) / span).clamp(0.0, 1.0).toDouble();
    }
    _tone = tone;

    // Each band against its own 98th percentile (of the sounding part).
    Float32List normalize(Float32List band) {
      final vals = <double>[
        for (var i = 0; i < n; i += stride)
          if (sums[i] > loudest * 0.05) band[i],
      ]..sort();
      final top = math.max(1e-9, vals[math.min(vals.length - 1, (vals.length * 0.98).floor())]);
      final out = Float32List(n);
      for (var i = 0; i < n; i++) {
        out[i] = (band[i] / top).clamp(0.0, 1.0).toDouble();
      }
      return out;
    }

    _lowN = normalize(lo);
    _midN = normalize(mi);
    _highN = normalize(hi);
    _ovColsFor = -1;
  }

  /// Overview columns (3 px pitch): mean of each normalized band per column.
  Float32List _overviewColumns(double width) {
    final n = math.min(_lowN.length, math.min(_midN.length, _highN.length));
    final cols = (width / 3).floor();
    if (n == 0 || cols <= 0) return Float32List(0);
    if (cols == _ovColsFor) return _ovCols;
    final out = Float32List(cols * 3);
    for (var c = 0; c < cols; c++) {
      final i0 = (c * n / cols).floor();
      final i1 = math.max(i0 + 1, ((c + 1) * n / cols).floor());
      var l = 0.0, m = 0.0, h = 0.0;
      for (var i = i0; i < i1; i++) {
        l += _lowN[i];
        m += _midN[i];
        h += _highN[i];
      }
      final k = (i1 - i0).toDouble();
      out[c * 3] = l / k;
      out[c * 3 + 1] = m / k;
      out[c * 3 + 2] = h / k;
    }
    _ovCols = out;
    _ovColsFor = cols;
    return out;
  }

  void _syncTicker() {
    if (widget.playing && !_ticker.isActive) {
      // Ticker elapsed restarts at zero when started.
      _now = _baseAt = Duration.zero;
      _ticker.start();
    } else if (!widget.playing && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onFrame(Duration elapsed) {
    _now = elapsed;
    final dt = (elapsed - _baseAt).inMicroseconds / 1e6;
    final ease = math.exp(-dt / _easeSec);
    var t = _base + dt * _scrollRate(widget) + _error * ease;
    final w = widget;
    final loopLen = w.loopEnd - w.loopStart;
    if (w.loopEnabled && loopLen > 0 && _base <= w.loopEnd && t > w.loopEnd) {
      t = w.loopStart + (t - w.loopEnd) % loopLen;
    }
    final next = t.clamp(0.0, w.duration).toDouble();
    if (next == _shown) return;
    setState(() => _shown = next);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w0 = widget;
    final shown = w0.playing ? _shown : w0.position;
    final palette = SideDeckColors.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 300.0;
        final h = constraints.maxHeight.isFinite && constraints.maxHeight > 0
            ? constraints.maxHeight
            : 88.0;
        final paint = CustomPaint(
          painter: WaveformPainter(
            min: w0.min,
            max: w0.max,
            binSec: w0.binSec,
            position: shown,
            duration: w0.duration,
            beatOffset: w0.beatOffset,
            bpm: w0.bpm,
            rate: w0.rate,
            color: w0.color,
            peak: _peak,
            palette: palette,
            style: w0.style,
            tone: _tone,
            overviewBands: _overviewColumns(w),
            loopEnabled: w0.loopEnabled,
            loopStart: w0.loopStart,
            loopEnd: w0.loopEnd,
            zoomWindowSec: WaveformView.zoom,
            showJumpZone: w0.onSeek != null,
          ),
          size: Size(w, h),
        );
        if ((w0.onSeek == null && w0.onOverviewSeek == null) ||
            w0.duration <= 0) {
          return paint;
        }
        return GestureDetector(
          onTapDown: (d) {
            final nx = (d.localPosition.dx / w).clamp(0.0, 1.0);
            if (d.localPosition.dy < WaveformPainter.overviewH) {
              w0.onOverviewSeek?.call(nx * w0.duration);
              return;
            }
            if (w0.onSeek == null) return;
            if ((nx - 0.5).abs() > WaveformPainter.jumpHalf) return;
            final playRate = w0.rate.clamp(0.5, 2.0);
            final heard = (nx - 0.5) * WaveformView.zoom;
            final t = shown + heard * playRate;
            w0.onSeek!(t.clamp(0.0, w0.duration).toDouble());
          },
          child: paint,
        );
      },
    );
  }
}
