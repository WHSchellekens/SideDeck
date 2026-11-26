import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:sidedeck/engine/native_lib.dart';

typedef _CreateC = Pointer<Void> Function();
typedef _DestroyC = Void Function(Pointer<Void>);
typedef _StartC = Int32 Function(Pointer<Void>);
typedef _StopC = Void Function(Pointer<Void>);
typedef _SetModeC = Int32 Function(Pointer<Void>, Int32);
typedef _GetIntC = Int32 Function(Pointer<Void>);
typedef _LoadC = Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>);
typedef _LastErrorC = Pointer<Utf8> Function();
typedef _LoadAnalyzedC = Int32 Function(
  Pointer<Void>,
  Int32,
  Pointer<Utf8>,
  Float,
  Int32,
  Float,
);
typedef _UnloadC = Void Function(Pointer<Void>, Int32);
typedef _PlayC = Void Function(Pointer<Void>, Int32, Int32);
typedef _SetFlagC = Void Function(Pointer<Void>, Int32);
typedef _GetDeckFloatC = Float Function(Pointer<Void>, Int32);
typedef _GetFloatC = Float Function(Pointer<Void>);
typedef _SeekC = Void Function(Pointer<Void>, Int32, Double);
typedef _PosC = Double Function(Pointer<Void>, Int32);
typedef _PlayingC = Int32 Function(Pointer<Void>, Int32);
typedef _SetFloatDeckC = Void Function(Pointer<Void>, Int32, Float);
typedef _SetEqC = Void Function(Pointer<Void>, Int32, Float, Float, Float);
typedef _SetXfaderC = Void Function(Pointer<Void>, Float);
typedef _SetMasterC = Void Function(Pointer<Void>, Float);
typedef _GetBpmC = Float Function(Pointer<Void>, Int32);
typedef _GetKeyC = Int32 Function(Pointer<Void>, Int32);
typedef _NudgeC = Void Function(Pointer<Void>, Int32, Float);
typedef _SetLoopC = Void Function(Pointer<Void>, Int32, Int32, Float);
typedef _BeatJumpC = Void Function(Pointer<Void>, Int32, Int32);
typedef _WaveLenC = Int32 Function(Pointer<Void>, Int32);
typedef _BandsCopyC = Int32 Function(
  Pointer<Void>,
  Int32,
  Pointer<Float>,
  Pointer<Float>,
  Pointer<Float>,
  Int32,
);
typedef _WaveCopyC = Int32 Function(
  Pointer<Void>,
  Int32,
  Pointer<Float>,
  Pointer<Float>,
  Int32,
);

class NativeEngine {
  NativeEngine._(this._lib, this._handle);

  final DynamicLibrary _lib;
  final Pointer<Void> _handle;
  bool started = false;

  late final _destroy = _lib.lookupFunction<_DestroyC, void Function(Pointer<Void>)>(
    'dj_destroy',
  );
  late final _start = _lib.lookupFunction<_StartC, int Function(Pointer<Void>)>(
    'dj_start',
  );
  late final _stop = _lib.lookupFunction<_StopC, void Function(Pointer<Void>)>(
    'dj_stop',
  );
  late final _setMode = _lib
      .lookupFunction<_SetModeC, int Function(Pointer<Void>, int)>(
        'dj_set_output_mode',
      );
  late final _getChannels = _lib.lookupFunction<_GetIntC, int Function(Pointer<Void>)>(
    'dj_get_output_channels',
  );
  late final _load = _lib
      .lookupFunction<_LoadC, int Function(Pointer<Void>, int, Pointer<Utf8>)>(
        'dj_load',
      );
  late final _lastError = _lib
      .lookupFunction<_LastErrorC, Pointer<Utf8> Function()>('dj_last_error');
  late final _loadAnalyzed = _lib.lookupFunction<
    _LoadAnalyzedC,
    int Function(Pointer<Void>, int, Pointer<Utf8>, double, int, double)
  >('dj_load_with_analysis');
  late final _unload = _lib
      .lookupFunction<_UnloadC, void Function(Pointer<Void>, int)>('dj_unload');
  late final _play = _lib
      .lookupFunction<_PlayC, void Function(Pointer<Void>, int, int)>('dj_play');
  late final _setQuantize = _lib
      .lookupFunction<_SetFlagC, void Function(Pointer<Void>, int)>(
        'dj_set_quantize',
      );
  late final _onAirEnable = _lib
      .lookupFunction<_SetFlagC, void Function(Pointer<Void>, int)>(
        'dj_onair_enable',
      );
  late final _onAirShare = _lib
      .lookupFunction<_GetDeckFloatC, double Function(Pointer<Void>, int)>(
        'dj_onair_share',
      );
  late final _onAirLag = _lib
      .lookupFunction<_GetFloatC, double Function(Pointer<Void>)>(
        'dj_onair_lag_ms',
      );
  late final _onAirFit = _lib
      .lookupFunction<_GetFloatC, double Function(Pointer<Void>)>(
        'dj_onair_fit',
      );
  late final _inputChannels = _lib
      .lookupFunction<_GetIntC, int Function(Pointer<Void>)>(
        'dj_input_channels',
      );
  late final _inputLevel = _lib
      .lookupFunction<_GetDeckFloatC, double Function(Pointer<Void>, int)>(
        'dj_input_level',
      );
  late final _seek = _lib
      .lookupFunction<_SeekC, void Function(Pointer<Void>, int, double)>('dj_seek');
  late final _position = _lib
      .lookupFunction<_PosC, double Function(Pointer<Void>, int)>('dj_position');
  late final _duration = _lib
      .lookupFunction<_PosC, double Function(Pointer<Void>, int)>('dj_duration');
  late final _playing = _lib
      .lookupFunction<_PlayingC, int Function(Pointer<Void>, int)>('dj_playing');
  late final _setGain = _lib
      .lookupFunction<_SetFloatDeckC, void Function(Pointer<Void>, int, double)>(
        'dj_set_gain',
      );
  late final _setEq = _lib
      .lookupFunction<
        _SetEqC,
        void Function(Pointer<Void>, int, double, double, double)
      >('dj_set_eq');
  late final _setFilter = _lib
      .lookupFunction<_SetFloatDeckC, void Function(Pointer<Void>, int, double)>(
        'dj_set_filter',
      );
  late final _setFader = _lib
      .lookupFunction<_SetFloatDeckC, void Function(Pointer<Void>, int, double)>(
        'dj_set_fader',
      );
  late final _setXfader = _lib
      .lookupFunction<_SetXfaderC, void Function(Pointer<Void>, double)>(
        'dj_set_xfader',
      );
  late final _setMaster = _lib
      .lookupFunction<_SetMasterC, void Function(Pointer<Void>, double)>(
        'dj_set_master',
      );
  late final _setRate = _lib
      .lookupFunction<_SetFloatDeckC, void Function(Pointer<Void>, int, double)>(
        'dj_set_rate',
      );
  late final _getBpm = _lib
      .lookupFunction<_GetBpmC, double Function(Pointer<Void>, int)>('dj_get_bpm');
  late final _getKey = _lib
      .lookupFunction<_GetKeyC, int Function(Pointer<Void>, int)>('dj_get_key');
  late final _getBeatOffset = _lib
      .lookupFunction<_GetBpmC, double Function(Pointer<Void>, int)>(
        'dj_get_beat_offset',
      );
  late final _nudgeGrid = _lib
      .lookupFunction<_NudgeC, void Function(Pointer<Void>, int, double)>(
        'dj_nudge_grid',
      );
  late final _setLoop = _lib
      .lookupFunction<_SetLoopC, void Function(Pointer<Void>, int, int, double)>(
        'dj_set_loop',
      );
  late final _loopStart = _lib
      .lookupFunction<_PosC, double Function(Pointer<Void>, int)>('dj_loop_start');
  late final _loopEnd = _lib
      .lookupFunction<_PosC, double Function(Pointer<Void>, int)>('dj_loop_end');
  late final _beatJump = _lib
      .lookupFunction<_BeatJumpC, void Function(Pointer<Void>, int, int)>(
        'dj_beat_jump',
      );
  late final _waveLength = _lib
      .lookupFunction<_WaveLenC, int Function(Pointer<Void>, int)>('dj_waveform_length');
  late final _waveBinSec = _lib
      .lookupFunction<_PosC, double Function(Pointer<Void>, int)>('dj_waveform_bin_seconds');
  late final _bandsCopy = _lib
      .lookupFunction<
        _BandsCopyC,
        int Function(
          Pointer<Void>,
          int,
          Pointer<Float>,
          Pointer<Float>,
          Pointer<Float>,
          int,
        )
      >('dj_waveform_bands_copy');
  late final _waveCopy = _lib
      .lookupFunction<
        _WaveCopyC,
        int Function(
          Pointer<Void>,
          int,
          Pointer<Float>,
          Pointer<Float>,
          int,
        )
      >('dj_waveform_copy');

  static NativeEngine open() {
    late final DynamicLibrary lib;
    try {
      lib = openDjEngine();
    } catch (e) {
      throw StateError('Failed to open dj_engine library: $e');
    }
    late final Pointer<Void> Function() create;
    try {
      create = lib.lookupFunction<_CreateC, _CreateC>('dj_create');
    } catch (e) {
      throw StateError(
        'dj_create missing — native engine not linked into the iOS binary: $e',
      );
    }
    final handle = create();
    if (handle.address == 0) {
      throw StateError('dj_create returned null');
    }
    final engine = NativeEngine._(lib, handle);
    engine.started = engine._start(handle) == 1;
    return engine;
  }

  void dispose() {
    _stop(_handle);
    _destroy(_handle);
  }

  bool setExternalMixer(bool enabled) {
    final ok = _setMode(_handle, enabled ? 1 : 0) == 1;
    if (ok) started = true;
    return ok;
  }

  int get outputChannels => _getChannels(_handle);
  int get nativeHandle => _handle.address;

  bool load(
    int deck,
    String path, {
    double? bpm,
    int? key,
    double? beatOffset,
  }) {
    final p = path.toNativeUtf8();
    try {
      if (bpm != null && bpm > 1) {
        return _loadAnalyzed(
              _handle,
              deck,
              p,
              bpm,
              key ?? -1,
              beatOffset ?? 0,
            ) ==
            1;
      }
      return _load(_handle, deck, p) == 1;
    } finally {
      malloc.free(p);
    }
  }

  /// Reason for the last failed [load], or empty if none / success.
  String lastError() {
    final ptr = _lastError();
    if (ptr == nullptr) return '';
    return ptr.toDartString();
  }

  void unload(int deck) => _unload(_handle, deck);
  void play(int deck, bool playing) => _play(_handle, deck, playing ? 1 : 0);
  void setQuantize(bool enabled) => _setQuantize(_handle, enabled ? 1 : 0);

  /// On-air detection from the external mixer's master return.
  void setOnAirTracking(bool enabled) => _onAirEnable(_handle, enabled ? 1 : 0);
  /// Share of the master explained by [deck], 0..1; negative while unknown.
  double onAirShare(int deck) => _onAirShare(_handle, deck);
  /// Phone-to-mixer-and-back delay in ms; negative until found.
  double onAirLagMs() => _onAirLag(_handle);
  double onAirFit() => _onAirFit(_handle);
  int inputChannels() => _inputChannels(_handle);
  double inputLevel(int channel) => _inputLevel(_handle, channel);
  void seek(int deck, double seconds) => _seek(_handle, deck, seconds);
  double position(int deck) => _position(_handle, deck);
  double duration(int deck) => _duration(_handle, deck);
  bool isPlaying(int deck) => _playing(_handle, deck) == 1;
  void setGain(int deck, double v) => _setGain(_handle, deck, v);
  void setEq(int deck, double low, double mid, double high) =>
      _setEq(_handle, deck, low, mid, high);
  void setFilter(int deck, double amount) => _setFilter(_handle, deck, amount);
  void setFader(int deck, double v) => _setFader(_handle, deck, v);
  void setXfader(double x) => _setXfader(_handle, x);
  void setMaster(double v) => _setMaster(_handle, v);
  void setRate(int deck, double rate) => _setRate(_handle, deck, rate);
  double bpm(int deck) => _getBpm(_handle, deck);
  int key(int deck) => _getKey(_handle, deck);
  double beatOffset(int deck) => _getBeatOffset(_handle, deck);
  void nudgeGrid(int deck, double seconds) => _nudgeGrid(_handle, deck, seconds);
  void setLoop(int deck, bool enabled, double bars) =>
      _setLoop(_handle, deck, enabled ? 1 : 0, bars);
  double loopStart(int deck) => _loopStart(_handle, deck);
  double loopEnd(int deck) => _loopEnd(_handle, deck);
  void beatJump(int deck, int beats) => _beatJump(_handle, deck, beats);

  /// Peaks per waveform bin; each bin is [binSec] of audio (2.5 ms).
  ({Float32List min, Float32List max, double binSec}) waveform(int deck) {
    final bins = _bins(deck);
    final minPtr = malloc<Float>(bins);
    final maxPtr = malloc<Float>(bins);
    try {
      final n = _waveCopy(_handle, deck, minPtr, maxPtr, bins);
      return (
        min: Float32List.fromList(minPtr.asTypedList(n)),
        max: Float32List.fromList(maxPtr.asTypedList(n)),
        binSec: _waveBinSec(_handle, deck),
      );
    } finally {
      malloc.free(minPtr);
      malloc.free(maxPtr);
    }
  }

  /// RMS per waveform bin in the EQ's low / mid / high bands.
  ({Float32List low, Float32List mid, Float32List high}) waveformBands(int deck) {
    final bins = _bins(deck);
    final lo = malloc<Float>(bins);
    final mi = malloc<Float>(bins);
    final hi = malloc<Float>(bins);
    try {
      final n = _bandsCopy(_handle, deck, lo, mi, hi, bins);
      return (
        low: Float32List.fromList(lo.asTypedList(n)),
        mid: Float32List.fromList(mi.asTypedList(n)),
        high: Float32List.fromList(hi.asTypedList(n)),
      );
    } finally {
      malloc.free(lo);
      malloc.free(mi);
      malloc.free(hi);
    }
  }

  /// Waveform bins of the loaded track; at least 1 so the buffers allocate.
  int _bins(int deck) {
    final n = _waveLength(_handle, deck);
    return n < 1 ? 1 : n;
  }
}
