import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
    this.rate = 1,
    this.loopEnabled = false,
    this.loopStart = 0,
    this.loopEnd = 0,
    this.zoomWindowSec = 8,
    this.showJumpZone = false,
  });

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
  static const overviewH = 16.0;
  static const jumpHalf = 0.14;
  static const _cell = 12.0;

  /// Left edge of the beat-jump hit rect; same math as [_drawJumpZone].
  static double jumpZoneLeft(double width) => width * (0.5 - jumpHalf);

  /// Right edge of the beat-jump hit rect.
  static double jumpZoneRight(double width) => width * (0.5 + jumpHalf);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.screen);

    if (min.isEmpty || duration <= 0 || size.width <= 1 || size.height <= 1) {
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

    _drawCells(canvas, Rect.fromLTWH(0, waveTop, size.width, waveH));
    _drawOverview(canvas, size, n, viewStart, viewEnd);

    final half = waveH * waveHeight / 2;
    final paint = Paint();
    for (var px = 0.0; px < size.width; px++) {
      final t0 = viewStart + (px / size.width) * viewDur;
      final t1 = viewStart + ((px + 1) / size.width) * viewDur;
      if (t1 <= 0 || t0 >= duration) continue;
      final loHi = _minMaxInRange(t0.clamp(0.0, duration), t1.clamp(0.0, duration), n, duration);
      final amp = math.max(loHi.$1.abs(), loHi.$2.abs()) / peak;
      final yHi = mid - (loHi.$2.abs() / peak) * half;
      final yLo = mid + (loHi.$1.abs() / peak) * half;
      paint.color = _ampColor(color, amp);
      canvas.drawRect(Rect.fromLTWH(px, yHi, 1.05, (yLo - yHi).clamp(1.0, waveH)), paint);
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
    final bars = Paint()..color = palette.stripBars;
    for (var px = 0.0; px < size.width; px += 3) {
      final t0 = (px / size.width) * duration;
      final t1 = ((px + 3) / size.width) * duration;
      final amp = _peakInRange(t0, t1, n, duration, peak).clamp(0.0, 1.0);
      final h = math.max(1.0, amp * (overviewH - 6));
      canvas.drawRect(Rect.fromLTWH(px, overviewH - 2 - h, 2, h), bars);
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
    final halo = Paint()..color = palette.halo;
    final bar = Paint()..color = palette.lit;
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
      final w = phrase ? 3.2 : 2.2;
      halo.strokeWidth = w + 2;
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
        oldDelegate.loopEnabled != loopEnabled ||
        oldDelegate.loopStart != loopStart ||
        oldDelegate.loopEnd != loopEnd ||
        oldDelegate.showJumpZone != showJumpZone;
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
    this.playing = false,
    this.beatOffset = 0,
    this.bpm = 0,
    this.rate = 1,
    this.scrollRate,
    this.loopEnabled = false,
    this.loopStart = 0,
    this.loopEnd = 0,
    this.onSeek,
    this.onOverviewSeek,
  });

  final Float32List min;
  final Float32List max;
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

  static const _snapSec = 0.25;
  static const _easeSec = 0.1;

  @override
  void initState() {
    super.initState();
    _base = _shown = widget.position;
    _refreshPeak();
    _syncTicker();
  }

  @override
  void didUpdateWidget(WaveformView old) {
    super.didUpdateWidget(old);
    if (!identical(widget.min, old.min) || !identical(widget.max, old.max)) {
      _refreshPeak();
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
            position: shown,
            duration: w0.duration,
            beatOffset: w0.beatOffset,
            bpm: w0.bpm,
            rate: w0.rate,
            color: w0.color,
            peak: _peak,
            palette: palette,
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
