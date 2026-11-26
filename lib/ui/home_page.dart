import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/engine/usb_output.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/state/ui_settings.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/ui/library_drawer.dart';
import 'package:sidedeck/ui/mixer_strip.dart';
import 'package:sidedeck/ui/settings_page.dart';
import 'package:sidedeck/ui/seven_segment.dart';
import 'package:sidedeck/ui/waveform.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.ui});

  final UiSettings ui;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  DjController? _dj;
  LibraryController? _library;
  String? _bootError;
  int? _gridEditDeck;
  bool _mixerDialogOpen = false;
  BuildContext? _mixerDialogContext;

  /// Only call from widgets built after a successful boot.
  DjController get _djReady => _dj!;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    try {
      final dj = DjController();
      final library = LibraryController();
      dj.addListener(_onDjChanged);
      _dj = dj;
      _library = library;
    } catch (e, st) {
      _bootError = '$e\n$st';
    }
  }

  @override
  void dispose() {
    final dj = _dj;
    if (dj != null) {
      dj.removeListener(_onDjChanged);
      dj.dispose();
    }
    _library?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  void _onDjChanged() {
    if (!mounted) return;
    final dj = _dj;
    if (dj == null) return;
    final err = dj.engineError;
    // Only when this route is on top — Settings shows its own SnackBar.
    if (err != null && (ModalRoute.of(context)?.isCurrent ?? false)) {
      final msg = err;
      dj.clearError();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      });
    }
    final offer = dj.mixerOffer;
    if (offer == null) {
      if (_mixerDialogOpen) _dismissMixerDialog();
      return;
    }
    if (_mixerDialogOpen) return;
    _mixerDialogOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final next = _dj?.mixerOffer;
      if (!mounted || next == null) {
        _mixerDialogOpen = false;
        return;
      }
      _showMixerOffer(next);
    });
  }

  void _dismissMixerDialog() {
    final ctx = _mixerDialogContext;
    if (ctx == null) return;
    _mixerDialogContext = null;
    if (ctx.mounted) Navigator.of(ctx).pop();
  }

  Future<void> _showMixerOffer(UsbMixerOffer offer) async {
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        _mixerDialogContext = ctx;
        return AlertDialog(
          title: Text('${offer.label} detected'),
          content: const Text(
            'Enable external mixer mode? Deck A and Deck B go out as '
            'separate channels so you mix on hardware.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Enable'),
            ),
          ],
        );
      },
    );
    _mixerDialogContext = null;
    _mixerDialogOpen = false;
    if (!mounted) return;
    final dj = _dj;
    if (dj == null) return;
    if (accepted == true) {
      await dj.acceptMixerOffer();
    } else if (dj.mixerOffer != null) {
      dj.declineMixerOffer();
    }
  }

  Future<void> _openSettings() async {
    final dj = _dj;
    if (dj == null) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => SettingsPage(dj: dj, ui: widget.ui)));
  }

  Future<void> _openLibrary() async {
    final dj = _dj;
    final library = _library;
    if (dj == null || library == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return FractionallySizedBox(
          heightFactor: 1,
          child: MediaQuery.removePadding(
            context: context,
            removeLeft: true,
            removeRight: true,
            child: LibraryOverlay(
              dj: dj,
              library: library,
              onOpenSettings: () async {
                Navigator.pop(context);
                await _openSettings();
              },
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final bootError = _bootError;
    if (bootError != null) {
      return Scaffold(
        backgroundColor: SideDeckTheme.bg,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: SelectableText(
              'SideDeck failed to start\n\n$bootError',
              style: const TextStyle(
                color: SideDeckTheme.text,
                fontSize: 13,
                fontFamily: 'Courier',
              ),
            ),
          ),
        ),
      );
    }

    final dj = _djReady;
    final library = _library!;
    final pal = SideDeckColors.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge([dj, library, widget.ui]),
      builder: (context, _) {
        return Scaffold(
          backgroundColor: pal.bg,
          body: SafeArea(
            child: ColoredBox(
              color: pal.bg,
              // External mixer: decks take the full height, Library and
              // Settings sit on a rail at the right edge. Phone mode keeps
              // the mixer strip underneath.
              child: dj.externalMixer
                  ? Row(
                      children: [
                        Expanded(
                          child: Column(
                            children: [
                              Expanded(child: _waveDeck(0)),
                              Expanded(child: _waveDeck(1)),
                              const SizedBox(height: 2),
                            ],
                          ),
                        ),
                        _rail(pal),
                      ],
                    )
                  : Column(
                      children: [
                        Expanded(flex: 5, child: _waveDeck(0)),
                        Expanded(flex: 5, child: _waveDeck(1)),
                        Expanded(flex: 7, child: _mixerBar()),
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }

  static const _railWidth = 52.0;

  Widget _rail(SideDeckColors pal) {
    final name = UsbOutput.deviceLabel(_djReady.usbDeviceName).toUpperCase();
    return SizedBox(
      width: _railWidth,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: pal.panel,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
              child: Column(
                children: [
                  _railButton(Icons.library_music, 'LIBRARY', _openLibrary, pal),
                  const SizedBox(height: 6),
                  _railButton(Icons.settings_outlined, 'SETTINGS', _openSettings, pal),
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: pal.lit,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'EXT MIXER · $name',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: 1,
                                  color: pal.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_gridEditDeck != null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _gridEditDeck = null),
              ),
            ),
        ],
      ),
    );
  }

  Widget _railButton(IconData icon, String label, VoidCallback onTap, SideDeckColors pal) {
    return Material(
      color: pal.unlit,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: double.infinity,
          height: 56,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 22, color: pal.pillText),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: pal.pillText,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Phone mode only: EQ, filter and crossfader under the decks.
  Widget _mixerBar() {
    return Stack(
      fit: StackFit.expand,
      children: [
        MixerStrip(
          controller: _djReady,
          onLibrary: _openLibrary,
          onSettings: _openSettings,
        ),
        if (_gridEditDeck != null)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _gridEditDeck = null),
            ),
          ),
      ],
    );
  }

  Widget _waveDeck(int i) {
    final pal = SideDeckColors.of(context);
    final deckColor = pal.deck(i);
    final d = _djReady.deck(i);
    final remaining = (d.duration - d.position).clamp(0.0, 99999.0);
    // Only when the mixer tells us (fader over MIDI, or heard in its master).
    final onAirKnown = _djReady.onAirSource(i) != OnAirSource.none;
    final showOnAir = onAirKnown && _djReady.onAir(i);

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final overview = WaveformPainter.overviewH;
            const pad = _overlayPad;
            final play = d.loaded
                ? (constraints.maxHeight - overview - 6).clamp(40.0, 120.0)
                : 0.0;
            final w = constraints.maxWidth;
            // Shrink pads so BPM cluster + nudges fit the side strip (no min floor
            // that would reintroduce overlap on very narrow widths).
            final side = w * (0.5 - WaveformPainter.jumpHalf);
            final padSize = ((side - pad - 3 * _wavePadGap) / 5).clamp(
              1.0,
              _wavePadSize,
            );
            final playFoot = pad + play;
            final nudgeFoot = pad + padSize * 2 + _wavePadGap;
            final loopGap = WaveformPainter.jumpZoneLeft(w) - playFoot;
            final bpmGap = w - WaveformPainter.jumpZoneRight(w) - nudgeFoot;
            return Stack(
              fit: StackFit.expand,
              children: [
                WaveformView(
                  min: d.waveMin,
                  max: d.waveMax,
                  position: d.position,
                  duration: d.duration,
                  playing: d.playing,
                  beatOffset: d.beatOffset,
                  bpm: d.bpm,
                  rate: d.rate,
                  scrollRate: _djReady.effectiveRate(i),
                  style: widget.ui.waveStyle,
                  low: d.waveLow,
                  mid: d.waveMid,
                  high: d.waveHigh,
                  color: deckColor,
                  loopEnabled: d.loopEnabled,
                  loopStart: d.loopStart,
                  loopEnd: d.loopEnd,
                  onSeek: d.loaded ? (t) => _djReady.seek(i, t) : null,
                  onOverviewSeek: d.loaded ? (t) => _djReady.seekTo(i, t) : null,
                ),
                if (!d.loaded)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _openLibrary,
                    ),
                  ),
                Positioned(
                  left: play + 12,
                  right: d.loaded ? (showOnAir ? 176 : 104) : 8,
                  top: overview + 5,
                  child: IgnorePointer(child: _info(i, d, remaining, pal)),
                ),
                if (d.loaded)
                  Positioned(
                    left: pad,
                    top: overview,
                    bottom: 0,
                    child: Center(child: _play(i, d.playing, play, pal)),
                  ),
                if (d.loaded)
                  Positioned(
                    right: pad,
                    bottom: pad,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _holdNudge(i, faster: false, size: padSize, pal: pal),
                        SizedBox(width: _wavePadGap),
                        _holdNudge(i, faster: true, size: padSize, pal: pal),
                      ],
                    ),
                  ),
                if (_gridEditDeck != null)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _gridEditDeck = null),
                    ),
                  ),
                if (d.loaded)
                  Positioned(
                    right: 4,
                    top: overview + 4,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (showOnAir) ...[
                          _onAirTag(pal),
                          const SizedBox(width: 6),
                        ],
                        _deckTag(i, deckColor),
                        const SizedBox(width: 6),
                        _gridButton(i, pal),
                      ],
                    ),
                  ),
                if (d.loaded && _gridEditDeck == i)
                  Positioned(
                    left: play + 8,
                    right: nudgeFoot,
                    bottom: 4,
                    child: _gridEditorBar(i, pal),
                  ),
                if (d.loaded && _gridEditDeck != i && loopGap > 0)
                  Positioned(
                    left: playFoot,
                    width: loopGap,
                    bottom: pad,
                    child: Center(
                      child: _waveLoop(i, pal, size: padSize),
                    ),
                  ),
                if (d.loaded && _gridEditDeck != i && bpmGap > 0)
                  Positioned(
                    left: WaveformPainter.jumpZoneRight(w),
                    width: bpmGap,
                    bottom: pad,
                    child: Center(
                      child: _waveBpm(i, pal, size: padSize),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Title in capitals like the Sidekick's screen; BPM, key and time after it
  /// in the same face.
  Widget _info(int i, DeckState d, double remaining, SideDeckColors pal) {
    final shadows = pal.brightness == Brightness.dark
        ? const [
            Shadow(color: Colors.black, blurRadius: 6),
            Shadow(color: Colors.black, blurRadius: 12),
          ]
        : const <Shadow>[];
    if (!d.loaded) {
      return Text(
        'DECK ${i == 0 ? 'A' : 'B'} — TAP TO LOAD A TRACK',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.6,
          color: pal.muted,
          shadows: shadows,
        ),
      );
    }
    final title = d.artist.isEmpty ? d.title : '${d.title} — ${d.artist}';
    final text = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: title.toUpperCase(),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.6,
              color: pal.text,
            ),
          ),
          TextSpan(
            // The track's own BPM by the key; what you hear is on the LCD.
            text: '   ${d.bpm > 1 ? '${d.bpm.toStringAsFixed(1)} BPM' : '— BPM'}'
                '   ${formatKey(d.key)}   −${formatDuration(remaining)}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.4,
              color: pal.muted,
            ),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        shadows: shadows,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    return Row(
      children: [
        _tempoLcd(d),
        const SizedBox(width: 10),
        Expanded(child: text),
      ],
    );
  }

  /// The tempo you hear, on a small LCD like the Sidekick's own BPM readout:
  /// segment digits only where there is a screen. Black glass in both themes.
  Widget _tempoLcd(DeckState d) {
    final heard = d.bpm > 1 ? (d.bpm * d.rate).toStringAsFixed(1) : '—';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFF2A1208)),
      ),
      child: SevenSegmentText(
        heard.padLeft(5),
        color: SideDeckTheme.lit,
        ghost: SideDeckTheme.ember.withValues(alpha: 0.45),
        height: 17,
      ),
    );
  }

  /// Play/pause starts on finger-up (tap), on purpose.
  Widget _play(int i, bool playing, double size, SideDeckColors pal) {
    return Material(
      color: pal.text.withValues(alpha: 0.07),
      shape: CircleBorder(
        side: BorderSide(
          color: playing ? pal.lit : pal.muted.withValues(alpha: 0.5),
          width: 2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _djReady.playPause(i),
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            playing ? Icons.pause : Icons.play_arrow,
            color: pal.text,
            size: size * 0.5,
          ),
        ),
      ),
    );
  }

  /// Lit like a Sidekick pill: this deck is in the main mix.
  Widget _onAirTag(SideDeckColors pal) {
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: pal.lit,
        borderRadius: BorderRadius.circular(5),
      ),
      child: const Text(
        'ON AIR',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: Colors.black,
        ),
      ),
    );
  }

  Widget _deckTag(int i, Color deckColor) {
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: deckColor,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        i == 0 ? 'A' : 'B',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: deckColor.computeLuminance() > 0.2 ? Colors.black : Colors.white,
        ),
      ),
    );
  }

  Widget _gridButton(int deck, SideDeckColors pal) {
    final on = _gridEditDeck == deck;
    return Material(
      color: on ? pal.lit : pal.unlit,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: () => setState(() => _gridEditDeck = on ? null : deck),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          child: Text(
            'GRID',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: on ? Colors.black : pal.pillText,
            ),
          ),
        ),
      ),
    );
  }

  Widget _gridEditorBar(int deck, SideDeckColors pal) {
    Widget step(String label, VoidCallback onStep) {
      return HoldRepeatButton(
        onStep: onStep,
        child: Container(
          width: 48,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: pal.unlit,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              height: 1,
              color: pal.pillText,
            ),
          ),
        ),
      );
    }

    Widget pair(String caption, Widget left, Widget right) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          left,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              caption.toUpperCase(),
              style: TextStyle(fontSize: 11, letterSpacing: 0.6, color: pal.muted),
            ),
          ),
          right,
        ],
      );
    }

    return Material(
      color: pal.panel.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            pair(
              'beat',
              step('«', () => _djReady.shiftGridBeats(deck, -1)),
              step('»', () => _djReady.shiftGridBeats(deck, 1)),
            ),
            const SizedBox(width: 16),
            pair(
              '5 ms',
              step('‹', () => _djReady.shiftGridMs(deck, -5)),
              step('›', () => _djReady.shiftGridMs(deck, 5)),
            ),
          ],
        ),
      ),
    );
  }

  static const _overlayPad = 4.0;
  static const _wavePadSize = 56.0;
  static const _wavePadGap = 6.0;

  Widget _waveLoop(int deck, SideDeckColors pal, {required double size}) {
    final d = _djReady.deck(deck);
    final beats = d.loopBars * 4;
    final beatsLabel = (beats - beats.round()).abs() < 0.05
        ? '${beats.round()}'
        : beats.toStringAsFixed(1);
    final canHalf = beats > DjController.loopBeats.first + 0.05;
    final canDouble = beats < DjController.loopBeats.last - 0.05;
    final labelStyle = _wavePadLabelStyle(size, pal.pillText);
    final onText = d.loopEnabled ? Colors.black : pal.pillText;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HoldRepeatButton(
          enabled: canHalf,
          onStep: () => _djReady.halfLoop(deck),
          child: _wavePad(
            pal,
            size: size,
            child: Text('½', style: labelStyle),
          ),
        ),
        SizedBox(width: _wavePadGap),
        GestureDetector(
          onTap: () => _djReady.setLoop(
            deck,
            !d.loopEnabled,
            d.loopBars == 0 ? 1 : d.loopBars,
          ),
          child: _wavePad(
            pal,
            size: size,
            filled: d.loopEnabled,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    beatsLabel,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: size * 0.32,
                      fontWeight: FontWeight.w700,
                      height: 1,
                      color: onText,
                    ),
                  ),
                ),
                _padCaption('LOOP', size, onText),
              ],
            ),
          ),
        ),
        SizedBox(width: _wavePadGap),
        HoldRepeatButton(
          enabled: canDouble,
          onStep: () => _djReady.doubleLoop(deck),
          child: _wavePad(
            pal,
            size: size,
            child: Text('×2', style: labelStyle),
          ),
        ),
      ],
    );
  }

  Widget _waveBpm(int deck, SideDeckColors pal, {required double size}) {
    final d = _djReady.deck(deck);
    final labelStyle = _wavePadLabelStyle(size, pal.pillText);
    final onText = d.synced ? Colors.black : pal.pillText;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HoldRepeatButton(
          enabled: d.loaded && d.bpm > 1,
          onStep: () => _djReady.nudgeBpm(deck, -0.1),
          child: _wavePad(
            pal,
            size: size,
            child: Text('−', style: labelStyle),
          ),
        ),
        SizedBox(width: _wavePadGap),
        GestureDetector(
          onTap: d.loaded && _djReady.deck(1 - deck).loaded
              ? () => _djReady.sync(deck)
              : null,
          child: _wavePad(
            pal,
            size: size,
            filled: d.synced,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'SYNC',
                  style: TextStyle(
                    fontSize: size * 0.2,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                    color: onText,
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(width: _wavePadGap),
        HoldRepeatButton(
          enabled: d.loaded && d.bpm > 1,
          onStep: () => _djReady.nudgeBpm(deck, 0.1),
          child: _wavePad(
            pal,
            size: size,
            child: Text('+', style: labelStyle),
          ),
        ),
      ],
    );
  }

  static TextStyle _wavePadLabelStyle(double size, Color color) => TextStyle(
    fontSize: size * 0.32,
    fontWeight: FontWeight.w500,
    color: color,
  );

  static Widget _padCaption(String text, double size, Color color) => Text(
    text,
    style: TextStyle(
      fontSize: size * 0.15,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.8,
      color: color,
    ),
  );

  /// Sidekick pill: ember when off, lit orange when on.
  Widget _wavePad(
    SideDeckColors pal, {
    required Widget child,
    required double size,
    bool filled = false,
  }) {
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: filled ? pal.lit : pal.unlit,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(child: child),
      ),
    );
  }

  Widget _holdNudge(
    int deck, {
    required bool faster,
    required double size,
    required SideDeckColors pal,
  }) {
    final on = _djReady.deck(deck).loaded;
    final color = on ? pal.pillText : pal.muted;
    return Listener(
      onPointerDown: on ? (_) => _djReady.startNudge(deck, faster: faster) : null,
      onPointerUp: on ? (_) => _djReady.endNudge(deck) : null,
      onPointerCancel: on ? (_) => _djReady.endNudge(deck) : null,
      child: _wavePad(
        pal,
        size: size,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              faster ? Icons.arrow_forward : Icons.arrow_back,
              size: size * 0.39,
              color: color,
            ),
            _padCaption('NUDGE', size, color),
          ],
        ),
      ),
    );
  }
}
