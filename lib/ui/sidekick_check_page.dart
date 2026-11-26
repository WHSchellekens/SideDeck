import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Settles what the EP-136 docs don't: does the Sidekick send its faders over
/// MIDI while it mixes, does Android hand SideDeck its master output (USB
/// inputs 7-8), and how much latency the phone adds. Reads only; records
/// nothing.
class SidekickCheckPage extends StatefulWidget {
  const SidekickCheckPage({super.key, required this.dj});

  final DjController dj;

  @override
  State<SidekickCheckPage> createState() => _SidekickCheckPageState();
}

class _SidekickCheckPageState extends State<SidekickCheckPage> {
  Timer? _refresh;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _refresh = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _startListening() async {
    setState(() => _starting = true);
    await widget.dj.setListenToMixer(true);
    if (mounted) setState(() => _starting = false);
  }

  @override
  Widget build(BuildContext context) {
    final pal = SideDeckColors.of(context);
    final dj = widget.dj;
    final help = TextStyle(color: pal.muted, fontSize: 12, height: 1.4);
    return Scaffold(
      appBar: AppBar(title: const Text('Sidekick check')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Three things the Sidekick’s documentation doesn’t say. Each part below '
            'answers one on your unit. Nothing is recorded.',
            style: help,
          ),
          _section('1 · Faders over MIDI'),
          Text(
            'In the Sidekick’s system menu (button under the battery lid) keep USB on '
            'MULTI and set MIDI to ON. Turn on reading below, then move each fader and '
            'press each cue button. Watch the Sidekick’s meters as you turn it on: if '
            'the audio stops, this phone cuts USB audio while the MIDI port is open.',
            style: help,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Read the faders over MIDI'),
            value: dj.readMixerMidi,
            onChanged: (v) => dj.setReadMixerMidi(v),
          ),
          _row('MIDI port', dj.midiDevice.isEmpty ? 'none found' : dj.midiDevice),
          _row('Fader A (CC 7, ch 1)', _fader(dj.midiFader[0])),
          _row('Fader B (CC 7, ch 2)', _fader(dj.midiFader[1])),
          const SizedBox(height: 8),
          _log(pal, dj.midiLog),
          const SizedBox(height: 8),
          _verdict(pal, _midiVerdict(dj)),
          _section('2 · The master output over USB'),
          if (!dj.externalMixer)
            Text('Turn on Use external mixer in Settings first.', style: help)
          else if (!dj.listening)
            Row(
              children: [
                FilledButton(
                  onPressed: _starting ? null : _startListening,
                  child: const Text('Start listening'),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text('Asks for microphone access.', style: help)),
              ],
            )
          else ...[
            _row('Inputs Android opened', '${dj.listenChannels}'),
            const SizedBox(height: 8),
            _meters(pal, dj),
            const SizedBox(height: 8),
            Text(
              'Play a track with its fader up. 7–8 should follow the Sidekick’s main '
              'output; 1–6 are its own inputs. Turn the main volume down: if 7–8 drop '
              'too, the return is after the volume knob.',
              style: help,
            ),
          ],
          if (dj.listenNote.isNotEmpty) ...[
            const SizedBox(height: 8),
            _verdict(pal, dj.listenNote, warn: true),
          ],
          _section('3 · Latency and on-air'),
          _row(
            'Phone → Sidekick → phone',
            dj.mixerLatencyMs == null
                ? (dj.listening ? 'needs music with a fader up' : '—')
                : '≈ ${dj.mixerLatencyMs!.toStringAsFixed(1)} ms',
          ),
          _row('Deck A in the master', _share(dj.onAirShare(0))),
          _row('Deck B in the master', _share(dj.onAirShare(1))),
          _row('Fit', dj.listening && dj.onAirFit > 0 ? dj.onAirFit.toStringAsFixed(2) : '—'),
          const SizedBox(height: 8),
          Text(
            'The delay is measured from SideDeck rendering a deck to it coming back from '
            'the Sidekick, so it covers the phone’s output buffer, USB and the mixer. '
            'Switch Settings › USB buffer (Safe, Low, Ultra) and the Sidekick’s EQ style '
            'and compare. Pull a fader down: its deck’s share should fall to 0.',
            style: help,
          ),
        ],
      ),
    );
  }

  String _fader(int? v) => v == null ? 'not seen yet' : '$v / 127';

  String _share(double s) => s < 0 ? '—' : '${(s * 100).round()} %';

  String _midiVerdict(DjController dj) {
    if (!dj.readMixerMidi) {
      return 'MIDI reading is off. Turn it on above to test.';
    }
    if (dj.midiFader[0] != null || dj.midiFader[1] != null) {
      return 'Faders arrive while the Sidekick mixes. On air follows them, and the '
          'Sidekick’s controls could drive SideDeck.';
    }
    if (dj.midiDevice.isNotEmpty) {
      return 'MIDI port open, but no fader messages yet. If moving a fader shows '
          'nothing, this MIDI mode doesn’t send them while mixing.';
    }
    return 'No MIDI port from the Sidekick. Set MIDI to ON in its system menu.';
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Text(
          title.toUpperCase(),
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            letterSpacing: 0.8,
          ),
        ),
      );

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
            Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      );

  Widget _verdict(SideDeckColors pal, String text, {bool warn = false}) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: pal.panelAlt,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: warn ? pal.lit : pal.cellGrid),
        ),
        child: Text(text, style: const TextStyle(fontSize: 12, height: 1.4)),
      );

  Widget _log(SideDeckColors pal, List<String> lines) {
    final shown = lines.length > 12 ? lines.sublist(lines.length - 12) : lines;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: pal.screen,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: pal.cellGrid),
      ),
      child: Text(
        shown.isEmpty ? 'No MIDI messages yet.' : shown.join('\n'),
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.4,
          color: shown.isEmpty ? pal.muted : pal.text,
        ),
      ),
    );
  }

  /// One bar per USB input; 7-8 (the master return) in lit orange.
  Widget _meters(SideDeckColors pal, DjController dj) {
    final n = math.min(8, math.max(dj.inputChannels, dj.listenChannels));
    return SizedBox(
      height: 96,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var c = 0; c < n; c++) ...[
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: pal.panelAlt,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: _meterFraction(dj.inputLevel(c)),
                        widthFactor: 1,
                        child: Container(
                          decoration: BoxDecoration(
                            color: c >= 6 ? pal.lit : pal.deckA,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${c + 1}',
                    style: TextStyle(fontSize: 11, color: c >= 6 ? pal.lit : pal.muted),
                  ),
                ],
              ),
            ),
            if (c < n - 1) const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  /// Peak to bar height on a 60 dB scale.
  static double _meterFraction(double peak) {
    if (peak <= 0) return 0;
    final db = 20 * math.log(peak) / math.ln10;
    return ((db + 60) / 60).clamp(0.0, 1.0).toDouble();
  }
}
