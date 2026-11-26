import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/engine/analysis_cache.dart';
import 'package:sidedeck/engine/native_engine.dart';
import 'package:sidedeck/engine/sidekick_link.dart';
import 'package:sidedeck/engine/track_analyzer.dart';
import 'package:sidedeck/engine/usb_output.dart';
import 'package:sidedeck/state/played_tracks.dart';

/// What tells SideDeck that a deck is in the external mixer's main mix.
enum OnAirSource {
  /// Nothing: a playing deck counts as on air.
  none,
  /// The mixer's fader, sent over USB MIDI (CC 7 on channel 1 or 2).
  midi,
  /// Listening to the mixer's master return (USB inputs 7-8).
  listening,
}

class DeckState {
  String? path;
  String title = 'Empty';
  String artist = '';
  bool loaded = false;
  bool playing = false;
  bool loopEnabled = false;
  double loopBars = 1;
  double loopStart = 0;
  double loopEnd = 0;
  double position = 0;
  double duration = 0;
  double bpm = 0;
  int key = -1;
  double rate = 1;
  bool synced = false;
  double beatOffset = 0;
  double gain = 1;
  double fader = 1;
  double filter = 0;
  double eqLow = 0;
  double eqMid = 0;
  double eqHigh = 0;
  Float32List waveMin = Float32List(0);
  Float32List waveMax = Float32List(0);
  /// Seconds of audio per waveform bin (fixed 2.5 ms).
  double waveBinSec = 0;
  /// RMS per waveform bin in the EQ's low / mid / high bands.
  Float32List waveLow = Float32List(0);
  Float32List waveMid = Float32List(0);
  Float32List waveHigh = Float32List(0);
}

class DjController extends ChangeNotifier {
  DjController() {
    _engine = NativeEngine.open();
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
    if (!_engine.started) {
      engineError = 'Audio engine failed to start.';
    }
    _usbSub = UsbOutput.events().listen(_onUsbEvent);
    _midiSub = SidekickLink.midi().listen(_onMidi);
    _loadPrefs();
  }

  static const _quantizePref = 'quantize';
  static const _usbBufferPref = 'usb_buffer';
  static const _listenPref = 'listen_to_mixer';
  /// A mixer fader at or below this (of 127) is down.
  static const _faderDown = 3;

  late final NativeEngine _engine;
  late final Timer _ticker;
  StreamSubscription<UsbHotplugEvent>? _usbSub;
  StreamSubscription<SidekickMidiEvent>? _midiSub;
  final AnalysisCache _analysisCache = AnalysisCache.instance;
  final Set<int> _declinedMixerIds = {};

  final DeckState deckA = DeckState();
  final DeckState deckB = DeckState();
  double xfader = 0.5;
  double master = 1.0;
  bool externalMixer = false;
  String usbDeviceName = '';
  int usbDeviceId = 0;
  UsbMixerOffer? mixerOffer;
  String? engineError;
  int? loadingDeck;
  String? loadingTitle;
  String? loadingPath;
  /// Settings > Quantize: a deck that starts while the other plays lands on
  /// its beat phase. The engine does the alignment; this mirrors the toggle.
  bool quantize = true;
  /// Settings > USB buffer (what you asked for).
  UsbBufferMode usbBuffer = UsbBufferMode.safe;
  /// What the running USB track actually uses (Safe after a fallback).
  UsbBufferMode? usbActiveBuffer;
  /// Tracks played in this set (30 s on a deck), for the library.
  final PlayedTracks played = PlayedTracks();
  final List<PlayClock> _playClocks = [PlayClock(), PlayClock()];
  DateTime? _lastTick;
  bool _disposed = false;

  /// Settings > Listen to the mixer: capture its USB inputs (master on 7-8)
  /// for on-air detection and latency. Android, external mixer only.
  bool listenToMixer = false;
  /// Capture is running.
  bool listening = false;
  /// USB inputs Android opened (8 includes the master return).
  int listenChannels = 0;
  /// Why listening is off or partial, '' when fine.
  String listenNote = '';
  /// The mixer's MIDI port, '' when there is none.
  String midiDevice = '';
  /// Last fader position per deck from the mixer's MIDI (0..127); null until
  /// the mixer has sent one.
  final List<int?> midiFader = [null, null];
  /// Newest MIDI messages from the mixer, for the check screen.
  final List<String> midiLog = [];
  final List<bool> _heardOnAir = [true, true];

  DeckState deck(int i) => i == 0 ? deckA : deckB;

  /// What decides whether deck [i] is on air right now.
  OnAirSource onAirSource(int i) {
    if (!externalMixer) return OnAirSource.none;
    if (midiFader[i] != null) return OnAirSource.midi;
    if (listening && listenChannels >= 8 && _engine.onAirShare(i) >= 0) {
      return OnAirSource.listening;
    }
    return OnAirSource.none;
  }

  /// Deck [i] is audible in the main mix: playing, and its fader up when the
  /// mixer tells us. With nothing to go on, playing counts.
  bool onAir(int i) {
    final d = deck(i);
    if (!d.loaded || !d.playing) return false;
    return switch (onAirSource(i)) {
      OnAirSource.midi => (midiFader[i] ?? 0) > _faderDown,
      OnAirSource.listening => _heardOnAir[i],
      OnAirSource.none => true,
    };
  }

  /// Phone-to-mixer-and-back delay measured while listening, in ms; null
  /// until there is music to measure it on.
  double? get mixerLatencyMs {
    if (!listening) return null;
    final lag = _engine.onAirLagMs();
    return lag >= 0 ? lag : null;
  }

  /// For the check screen.
  double onAirShare(int i) => listening ? _engine.onAirShare(i) : -1;
  double get onAirFit => listening ? _engine.onAirFit() : 0;
  int get inputChannels => listening ? _engine.inputChannels() : 0;
  double inputLevel(int channel) => listening ? _engine.inputLevel(channel) : 0;

  void _onMidi(SidekickMidiEvent e) {
    midiLog.add(e.describe());
    if (midiLog.length > 40) midiLog.removeAt(0);
    if (e.isDevice) {
      midiDevice = e.name;
      if (e.name.isEmpty) {
        midiFader[0] = null;
        midiFader[1] = null;
      }
      _emit();
      return;
    }
    // Fader: CC 7, or CC 9 while Select is held (guide, 8.1).
    if (e.kind == 'cc' && (e.number == 7 || e.number == 9) && e.channel <= 1) {
      midiFader[e.channel] = e.value;
    }
  }

  Future<void> setListenToMixer(bool enabled) async {
    listenToMixer = enabled;
    listenNote = '';
    _emit();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_listenPref, enabled);
    } catch (_) {}
    if (enabled && externalMixer) {
      await _startListening();
    } else if (!enabled) {
      await _stopListening();
    }
    _emit();
  }

  Future<void> _startListening() async {
    if (!Platform.isAndroid || listening) return;
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      listenNote = 'Listening needs microphone access. SideDeck only reads '
          'the mixer over USB and stores nothing.';
      return;
    }
    _engine.setOnAirTracking(true);
    final res = await SidekickLink.startListening(_engine.nativeHandle);
    if (_disposed) return;
    if (!res.ok) {
      _engine.setOnAirTracking(false);
      listenNote = res.error.isEmpty ? 'Could not listen to the mixer.' : res.error;
      return;
    }
    listening = true;
    listenChannels = res.channels;
    _heardOnAir[0] = true;
    _heardOnAir[1] = true;
    listenNote = res.channels >= 8
        ? ''
        : 'Android opened ${res.channels} of the mixer’s inputs, so its master '
            '(inputs 7–8) can’t be heard.';
  }

  Future<void> _stopListening() async {
    final was = listening;
    listening = false;
    listenChannels = 0;
    if (was) await SidekickLink.stopListening();
    _engine.setOnAirTracking(false);
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _loadPrefs() async {
    await played.load();
    try {
      final prefs = await SharedPreferences.getInstance();
      quantize = prefs.getBool(_quantizePref) ?? true;
      usbBuffer = UsbBufferMode.fromKey(prefs.getString(_usbBufferPref));
      listenToMixer = prefs.getBool(_listenPref) ?? false;
    } catch (_) {
      return;
    }
    if (_disposed) return;
    _engine.setQuantize(quantize);
    _emit();
  }

  Future<void> setQuantize(bool enabled) async {
    quantize = enabled;
    _engine.setQuantize(enabled);
    _emit();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_quantizePref, enabled);
    } catch (_) {}
  }

  /// Library > New set: forget which tracks were played.
  Future<void> newSet() async {
    await played.clear();
    _emit();
  }

  /// Saves the choice and, with the mixer on, restarts USB output with it
  /// (a short dropout).
  Future<void> setUsbBuffer(UsbBufferMode mode) async {
    if (usbBuffer == mode) return;
    usbBuffer = mode;
    _emit();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_usbBufferPref, mode.key);
    } catch (_) {}
    if (externalMixer && Platform.isAndroid) {
      await setExternalMixer(true);
    }
  }

  void clearError() {
    engineError = null;
    notifyListeners();
  }

  void _onUsbEvent(UsbHotplugEvent event) {
    if (event.attached) {
      _onUsbAttached(event);
    } else if (event.playbackStopped) {
      _onUsbPlaybackStopped(event);
    } else if (event.detached) {
      _onUsbDetached(event);
    }
  }

  void _onUsbPlaybackStopped(UsbHotplugEvent event) {
    if (!externalMixer) return;
    final name = UsbOutput.deviceLabel(
      usbDeviceName.isEmpty ? event.name : usbDeviceName,
    );
    setExternalMixer(false).then((_) {
      engineError = 'USB audio to $name stopped; audio is back on the phone.';
      notifyListeners();
    });
  }

  void _onUsbAttached(UsbHotplugEvent event) {
    if (externalMixer) return;
    if (_declinedMixerIds.contains(event.id)) return;
    if (mixerOffer?.id == event.id) return;
    mixerOffer = UsbMixerOffer(
      id: event.id,
      channels: event.channels,
      name: event.name,
    );
    notifyListeners();
  }

  void _onUsbDetached(UsbHotplugEvent event) {
    _declinedMixerIds.remove(event.id);
    final offeringThis = mixerOffer?.id == event.id;
    if (offeringThis) mixerOffer = null;
    if (externalMixer && usbDeviceId == event.id) {
      final name = UsbOutput.deviceLabel(
        usbDeviceName.isEmpty ? event.name : usbDeviceName,
      );
      setExternalMixer(false).then((_) {
        engineError = '$name disconnected; audio is back on the phone.';
        notifyListeners();
      });
      return;
    }
    if (offeringThis) notifyListeners();
  }

  Future<void> acceptMixerOffer() async {
    mixerOffer = null;
    notifyListeners();
    await setExternalMixer(true);
  }

  void declineMixerOffer() {
    final id = mixerOffer?.id;
    if (id != null) _declinedMixerIds.add(id);
    mixerOffer = null;
    notifyListeners();
  }

  void _tick() {
    final now = DateTime.now();
    final last = _lastTick;
    _lastTick = now;
    // Clamped so a stall (app in background) can't count as minutes of play.
    final dt = last == null
        ? 0.0
        : (now.difference(last).inMicroseconds / 1e6).clamp(0.0, 0.5).toDouble();
    if (listening) {
      // Hysteresis on the heard share: on above 20 %, off below 10 %.
      for (var i = 0; i < 2; i++) {
        final s = _engine.onAirShare(i);
        if (s < 0) continue;
        if (s >= 0.2) {
          _heardOnAir[i] = true;
        } else if (s < 0.1) {
          _heardOnAir[i] = false;
        }
      }
    }
    var dirty = false;
    for (var i = 0; i < 2; i++) {
      final d = deck(i);
      if (!d.loaded || !d.playing) continue;
      d.position = _engine.position(i);
      d.playing = _engine.isPlaying(i);
      if (d.loopEnabled) {
        _readLoop(i);
      }
      // Played = 30 s on air (fader up, when the mixer tells us).
      final path = d.path;
      if (path != null && onAir(i) && _playClocks[i].add(dt)) {
        played.mark(path, now);
      }
      dirty = true;
    }
    if (dirty) notifyListeners();
  }

  Future<bool> loadFile(
    int deckIndex,
    String path, {
    String? title,
    String? artist,
  }) async {
    loadingDeck = deckIndex;
    loadingTitle = title ?? path.split(RegExp(r'[\\/]')).last;
    loadingPath = path;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 16));

    TrackAnalysis? cached;
    try {
      final stat = await File(path).stat();
      cached = await _analysisCache.get(
        path,
        stat.size,
        stat.modified.millisecondsSinceEpoch,
      );
    } catch (_) {}

    final ok = _engine.load(
      deckIndex,
      path,
      bpm: cached?.bpm,
      key: cached?.key,
      beatOffset: cached?.beatOffset,
    );
    final d = deck(deckIndex);
    if (!ok) {
      loadingDeck = null;
      loadingTitle = null;
      loadingPath = null;
      final name = title ?? path.split(RegExp(r'[\\/]')).last;
      final detail = _engine.lastError();
      engineError = detail.isNotEmpty
          ? 'Could not load $name - $detail'
          : 'Could not decode $name (need MP3, WAV, FLAC, Opus, Ogg Vorbis, or AAC M4A).';
      notifyListeners();
      return false;
    }
    d.path = path;
    _playClocks[deckIndex].reset();
    d.title = title ?? path.split(RegExp(r'[\\/]')).last;
    d.artist = artist ?? '';
    d.loaded = true;
    d.playing = false;
    d.position = 0;
    d.duration = _engine.duration(deckIndex);
    d.bpm = _engine.bpm(deckIndex);
    d.key = _engine.key(deckIndex);
    d.beatOffset = _engine.beatOffset(deckIndex);
    d.rate = 1;
    d.synced = false;
    d.loopEnabled = false;
    d.loopStart = 0;
    d.loopEnd = 0;
    final wave = _engine.waveform(deckIndex);
    d.waveMin = wave.min;
    d.waveMax = wave.max;
    d.waveBinSec = wave.binSec;
    final bands = _engine.waveformBands(deckIndex);
    d.waveLow = bands.low;
    d.waveMid = bands.mid;
    d.waveHigh = bands.high;
    _engine.setRate(deckIndex, 1);
    _nudgeBend[deckIndex] = 0;
    _engine.setGain(deckIndex, d.gain);
    _engine.setFader(deckIndex, d.fader);
    _engine.setFilter(deckIndex, d.filter);
    _engine.setEq(deckIndex, d.eqLow, d.eqMid, d.eqHigh);

    if (cached == null) {
      try {
        final file = File(path);
        final stat = await file.stat();
        await _analysisCache.put(
          path: path,
          size: stat.size,
          mtime: stat.modified.millisecondsSinceEpoch,
          bpm: d.bpm,
          key: d.key,
          beatOffset: d.beatOffset,
        );
      } catch (_) {}
    }

    loadingDeck = null;
    loadingTitle = null;
    loadingPath = null;
    // If the other deck is synced to us and currently sounding, do not yank
    // its tempo to this new file. Hand tempo authority to the sounding deck.
    final other = 1 - deckIndex;
    if (deck(other).synced && deck(other).playing) {
      deck(other).synced = false;
    } else {
      _followMasterBpm(deckIndex);
    }
    notifyListeners();
    return true;
  }

  /// Re-read a track that was just re-analyzed, so a deck holding it picks up
  /// the new BPM and beat grid instead of keeping the stale one.
  Future<void> reloadIfLoaded(
    String path, {
    String? title,
    String? artist,
  }) async {
    for (var i = 0; i < 2; i++) {
      final d = deck(i);
      if (d.path != path) continue;
      await loadFile(
        i,
        path,
        title: title ?? d.title,
        artist: artist ?? d.artist,
      );
    }
  }

  void playPause(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    final next = !d.playing;
    _engine.play(deckIndex, next);
    d.playing = next;
    // Quantize may have moved the start onto the other deck's beat.
    if (next) d.position = _engine.position(deckIndex);
    notifyListeners();
  }

  /// Waveform tap: jump exactly 4 beats toward the tap. No grid snap —
  /// integer beat jumps keep relative phase.
  void seek(int deckIndex, double seconds) {
    final d = deck(deckIndex);
    if (!d.loaded) return;

    final target = seconds.clamp(0.0, math.max(0.0, d.duration)).toDouble();
    if (d.bpm > 1) {
      final dir = target.compareTo(d.position);
      if (dir == 0) return;
      _engine.beatJump(deckIndex, dir * 4);
      d.position = _engine.position(deckIndex);
      _readLoop(deckIndex);
      notifyListeners();
      return;
    }

    seekTo(deckIndex, target);
  }

  /// Absolute seek (overview scrub / pause nudge). Ignores beat-jump mode.
  void seekTo(int deckIndex, double seconds) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    final target = seconds.clamp(0.0, math.max(0.0, d.duration)).toDouble();
    _engine.seek(deckIndex, target);
    d.position = target;
    _readLoop(deckIndex);
    notifyListeners();
  }

  void setGain(int deckIndex, double v) {
    deck(deckIndex).gain = v;
    _engine.setGain(deckIndex, v);
    notifyListeners();
  }

  void setFader(int deckIndex, double v) {
    deck(deckIndex).fader = v;
    _engine.setFader(deckIndex, v);
    notifyListeners();
  }

  void setEq(int deckIndex, {double? low, double? mid, double? high}) {
    final d = deck(deckIndex);
    d.eqLow = low ?? d.eqLow;
    d.eqMid = mid ?? d.eqMid;
    d.eqHigh = high ?? d.eqHigh;
    _engine.setEq(deckIndex, d.eqLow, d.eqMid, d.eqHigh);
    notifyListeners();
  }

  void setFilter(int deckIndex, double amount) {
    deck(deckIndex).filter = amount;
    _engine.setFilter(deckIndex, amount);
    notifyListeners();
  }

  void setXfader(double x) {
    xfader = x;
    _engine.setXfader(x);
    notifyListeners();
  }

  void setMaster(double v) {
    master = v;
    _engine.setMaster(v);
    notifyListeners();
  }

  void setRate(int deckIndex, double rate) {
    final d = deck(deckIndex);
    d.rate = rate;
    d.synced = false;
    _applyRate(deckIndex);
    _followMasterBpm(deckIndex);
    notifyListeners();
  }

  final List<double> _nudgeBend = [0, 0]; // temporary pitch bend while held
  final List<Timer?> _nudgeHold = [null, null];

  /// Rate actually sent to the engine (includes temporary pitch bend).
  double effectiveRate(int deckIndex) {
    final d = deck(deckIndex);
    return (d.rate * (1.0 + _nudgeBend[deckIndex])).clamp(0.5, 2.0);
  }

  void _applyRate(int deckIndex) {
    _engine.setRate(deckIndex, effectiveRate(deckIndex));
  }

  /// ±0.1 BPM (heard tempo). Rate is derived from the track's original BPM.
  void nudgeBpm(int deckIndex, double delta) {
    final d = deck(deckIndex);
    if (!d.loaded || d.bpm <= 0) return;
    final heard = d.bpm * d.rate;
    final tenths = (heard * 10).round() + (delta * 10).round();
    final next = (tenths / 10.0).clamp(d.bpm * 0.5, d.bpm * 2.0);
    d.rate = next / d.bpm;
    d.synced = false;
    _applyRate(deckIndex);
    _followMasterBpm(deckIndex);
    notifyListeners();
  }

  /// Hold to briefly speed up (+) or slow down (−) for beatmatching.
  /// While paused, the same buttons jog the playhead so you can cue visually.
  void startNudge(int deckIndex, {required bool faster}) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    _nudgeHold[deckIndex]?.cancel();
    if (d.playing) {
      _nudgeBend[deckIndex] = faster ? 0.08 : -0.08;
      _applyRate(deckIndex);
      notifyListeners();
      return;
    }
    _jogPaused(deckIndex, faster: faster);
    _nudgeHold[deckIndex] = Timer(const Duration(milliseconds: 350), () {
      _nudgeHold[deckIndex] = Timer.periodic(const Duration(milliseconds: 50), (
        _,
      ) {
        if (!deck(deckIndex).playing) {
          _jogPaused(deckIndex, faster: faster);
        }
      });
    });
  }

  void endNudge(int deckIndex) {
    _nudgeHold[deckIndex]?.cancel();
    _nudgeHold[deckIndex] = null;
    _nudgeBend[deckIndex] = 0;
    _applyRate(deckIndex);
    notifyListeners();
  }

  void _jogPaused(int deckIndex, {required bool faster}) {
    final d = deck(deckIndex);
    if (!d.loaded || d.playing) return;
    const step = 0.04; // 40 ms — visible on the 8 s zoom window, still fine
    final t = (d.position + (faster ? step : -step))
        .clamp(0.0, math.max(0.0, d.duration))
        .toDouble();
    _engine.seek(deckIndex, t);
    d.position = t;
    notifyListeners();
  }

  void setLoop(int deckIndex, bool enabled, [double? bars]) {
    final d = deck(deckIndex);
    if (bars != null) d.loopBars = bars.clamp(0.25, 8.0);
    d.loopEnabled = enabled;
    _engine.setLoop(deckIndex, enabled, d.loopBars);
    _readLoop(deckIndex);
    notifyListeners();
  }

  static const loopBeats = [1.0, 2.0, 4.0, 8.0, 16.0, 32.0];

  void halfLoop(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    final beats = d.loopBars * 4;
    final i = loopBeats.indexWhere((b) => (b - beats).abs() < 0.05);
    final next = i <= 0 ? loopBeats.first : loopBeats[i - 1];
    setLoop(deckIndex, d.loopEnabled, next / 4.0);
  }

  void doubleLoop(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    final beats = d.loopBars * 4;
    var i = loopBeats.indexWhere((b) => (b - beats).abs() < 0.05);
    if (i < 0) i = 0;
    final next = i >= loopBeats.length - 1 ? loopBeats.last : loopBeats[i + 1];
    setLoop(deckIndex, d.loopEnabled, next / 4.0);
  }

  void _readLoop(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loopEnabled) {
      d.loopStart = 0;
      d.loopEnd = 0;
      return;
    }
    d.loopStart = _engine.loopStart(deckIndex);
    d.loopEnd = _engine.loopEnd(deckIndex);
  }

  void beatJump(int deckIndex, int beats) {
    _engine.beatJump(deckIndex, beats);
    deck(deckIndex).position = _engine.position(deckIndex);
    _readLoop(deckIndex);
    notifyListeners();
  }

  /// Match [slave] tempo to the other deck and keep following its BPM.
  /// Does not move the playhead. Press SYNC on the deck you want to change.
  void sync(int slave) {
    final masterIdx = 1 - slave;
    if (!deck(slave).loaded || !deck(masterIdx).loaded) return;
    _nudgeBend[slave] = 0;
    deck(slave).synced = true;
    deck(masterIdx).synced = false;
    _applySlaveTempo(slave);
    notifyListeners();
  }

  double _tempoMatchRate(DeckState slave, DeckState master) {
    final slaveBpm = slave.bpm <= 0 ? 1.0 : slave.bpm;
    return (master.bpm * master.rate / slaveBpm).clamp(0.5, 2.0);
  }

  void _applySlaveTempo(int slave) {
    final d = deck(slave);
    final master = deck(1 - slave);
    if (!d.loaded || !master.loaded) return;
    d.rate = _tempoMatchRate(d, master);
    _applyRate(slave);
  }

  /// If [deckIndex] is the master of a synced slave, keep that slave matched.
  void _followMasterBpm(int deckIndex) {
    final slave = 1 - deckIndex;
    if (!deck(slave).synced) return;
    _applySlaveTempo(slave);
  }

  void nudgeGrid(int deckIndex, double seconds) {
    _engine.nudgeGrid(deckIndex, seconds);
    final d = deck(deckIndex);
    d.beatOffset = _engine.beatOffset(deckIndex);
    notifyListeners();
    _persistAnalysis(d);
  }

  /// Shift the painted grid. Negative = earlier (yellow moves left).
  void shiftGridBeats(int deckIndex, int beats) {
    final d = deck(deckIndex);
    if (!d.loaded || d.bpm <= 1) return;
    nudgeGrid(deckIndex, beats * (60.0 / d.bpm));
  }

  void shiftGridMs(int deckIndex, int milliseconds) {
    if (!deck(deckIndex).loaded) return;
    nudgeGrid(deckIndex, milliseconds / 1000.0);
  }

  Future<void> _persistAnalysis(DeckState d) async {
    final path = d.path;
    if (path == null || path.isEmpty || d.bpm <= 0) return;
    try {
      final stat = await File(path).stat();
      await _analysisCache.put(
        path: path,
        size: stat.size,
        mtime: stat.modified.millisecondsSinceEpoch,
        bpm: d.bpm,
        key: d.key,
        beatOffset: d.beatOffset,
      );
    } catch (_) {}
  }

  Future<void> setExternalMixer(bool enabled) async {
    if (mixerOffer != null) {
      mixerOffer = null;
      notifyListeners();
    }
    var deviceId = 0;
    var usbChannels = 4;
    usbDeviceName = '';
    usbDeviceId = 0;
    usbActiveBuffer = null;
    await _stopListening();
    await UsbOutput.stopPlayback();
    if (enabled) {
      final usb = await UsbOutput.find();
      if (usb != null) {
        deviceId = usb.id;
        usbDeviceName = usb.name;
        if (usb.channels >= 8) usbChannels = 8;
      }
    }
    final prepared = _engine.setExternalMixer(enabled);
    if (enabled && prepared && Platform.isAndroid) {
      final res = await UsbOutput.startPlayback(
        engineHandle: _engine.nativeHandle,
        deviceId: deviceId,
        channels: usbChannels,
        bufferMode: usbBuffer,
      );
      externalMixer = res.ok;
      if (res.ok) {
        usbDeviceId = res.routedId != 0 ? res.routedId : deviceId;
        if (res.routedName.isNotEmpty) usbDeviceName = res.routedName;
        usbActiveBuffer = res.bufferMode;
        engineError = res.fallback
            ? 'USB buffer ${usbBuffer.label} did not start on this phone; using Safe.'
            : null;
      } else {
        await UsbOutput.stopPlayback();
        engineError =
            'This USB device cannot take Deck A and Deck B on separate '
            'channels; audio stayed on the phone.';
        _engine.setExternalMixer(false);
        externalMixer = false;
      }
    } else if (enabled && prepared && Platform.isIOS) {
      if (deviceId == 0) {
        _engine.setExternalMixer(false);
        externalMixer = false;
        engineError =
            'No USB mixer detected; audio stayed on the phone.';
      } else {
        externalMixer = true;
        usbDeviceId = deviceId;
        engineError = null;
      }
    } else if (enabled && !prepared) {
      engineError =
          'Could not open 4-channel USB output; audio stayed on the phone.';
      externalMixer = false;
    } else {
      externalMixer = false;
      if (!enabled) engineError = null;
    }
    if (externalMixer && listenToMixer && Platform.isAndroid) {
      await _startListening();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _usbSub?.cancel();
    _midiSub?.cancel();
    if (listening) SidekickLink.stopListening();
    _engine.setOnAirTracking(false);
    _ticker.cancel();
    _nudgeHold[0]?.cancel();
    _nudgeHold[1]?.cancel();
    UsbOutput.stopPlayback();
    _engine.dispose();
    super.dispose();
  }
}
