import 'dart:io';

import 'package:flutter/services.dart';

class UsbOutputInfo {
  const UsbOutputInfo({required this.id, required this.channels, required this.name});

  final int id;
  final int channels;
  final String name;
}

/// Settings > USB buffer. Safe is the original 50 ms path; Low and Ultra ask
/// Android for a low-latency track and fall back to Safe if it won't start.
enum UsbBufferMode {
  safe('safe', 'Safe', 50),
  low('low', 'Low', 20),
  ultra('ultra', 'Ultra', 10);

  const UsbBufferMode(this.key, this.label, this.targetMs);

  final String key;
  final String label;
  final int targetMs;

  static UsbBufferMode fromKey(String? key) => UsbBufferMode.values.firstWhere(
        (m) => m.key == key,
        orElse: () => UsbBufferMode.safe,
      );
}

class UsbStartResult {
  const UsbStartResult({
    required this.ok,
    required this.channels,
    required this.routedId,
    required this.routedName,
    required this.error,
    this.bufferMode = UsbBufferMode.safe,
    this.bufferFrames = 0,
    this.fallback = false,
    this.details = '',
  });

  final bool ok;
  final int channels;
  final int routedId;
  final String routedName;
  final String error;
  /// Buffer mode the running track actually uses.
  final UsbBufferMode bufferMode;
  final int bufferFrames;
  /// True when a Low/Ultra track failed and Safe was used instead.
  final bool fallback;
  /// What Android offered and did, one step per line, for Settings.
  final String details;
}

/// Live figures from the running USB track, for Settings.
class UsbStats {
  const UsbStats({
    required this.underruns,
    required this.latencyMs,
    required this.bufferFrames,
    required this.sampleRate,
    required this.bufferMode,
    required this.lowLatencyGranted,
  });

  final int underruns;
  /// Estimated time from writing a frame to it leaving the phone; negative when
  /// Android has no timestamp yet.
  final double latencyMs;
  final int bufferFrames;
  final int sampleRate;
  final UsbBufferMode bufferMode;
  final bool lowLatencyGranted;

  double get bufferMs => sampleRate > 0 ? bufferFrames * 1000.0 / sampleRate : 0;
}

class UsbHotplugEvent {
  const UsbHotplugEvent({
    required this.kind,
    required this.id,
    required this.channels,
    required this.name,
  });

  /// Native payload: `attached`, `detached`, or `playback_stopped`.
  final String kind;
  final int id;
  final int channels;
  final String name;

  bool get attached => kind == 'attached';
  bool get detached => kind == 'detached';
  bool get playbackStopped => kind == 'playback_stopped';
}

class UsbMixerOffer {
  const UsbMixerOffer({required this.id, required this.channels, required this.name});

  final int id;
  final int channels;
  final String name;

  String get label => UsbOutput.deviceLabel(name);
}

class UsbOutput {
  static const _ch = MethodChannel('sidedeck/audio');
  static const _events = EventChannel('sidedeck/usb');

  /// Android names USB outputs like "USB-Audio - EP-136"; show just the hardware.
  static String deviceLabel(String name) {
    final trimmed = name.split(' - ').last.trim();
    return trimmed.isEmpty ? 'mixer' : trimmed;
  }

  static Stream<UsbHotplugEvent>? _hotplug;

  static Stream<UsbHotplugEvent> events() {
    if (!Platform.isAndroid && !Platform.isIOS) return const Stream.empty();
    return _hotplug ??= _events.receiveBroadcastStream().map((raw) {
      final map = raw is Map ? raw : const {};
      return UsbHotplugEvent(
        kind: '${map['event'] ?? ''}',
        id: (map['id'] as num?)?.toInt() ?? 0,
        channels: (map['channels'] as num?)?.toInt() ?? 0,
        name: '${map['name'] ?? ''}',
      );
    });
  }

  static Future<UsbOutputInfo?> find() async {
    try {
      final raw = await _ch.invokeMethod<dynamic>('usbOutputDevice');
      if (raw is! Map) return null;
      final id = (raw['id'] as num?)?.toInt() ?? 0;
      if (id <= 0) return null;
      return UsbOutputInfo(
        id: id,
        channels: (raw['channels'] as num?)?.toInt() ?? 0,
        name: '${raw['name'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }

  static Future<UsbStartResult> startPlayback({
    required int engineHandle,
    required int deviceId,
    int channels = 4,
    UsbBufferMode bufferMode = UsbBufferMode.safe,
  }) async {
    try {
      final raw = await _ch.invokeMethod<dynamic>('startUsbPlayback', {
        'handle': engineHandle,
        'deviceId': deviceId,
        'channels': channels,
        'bufferMode': bufferMode.key,
      });
      if (raw is! Map) {
        return const UsbStartResult(
          ok: false,
          channels: 0,
          routedId: 0,
          routedName: '',
          error: 'No response from native audio',
        );
      }
      return UsbStartResult(
        ok: raw['ok'] == true,
        channels: (raw['channels'] as num?)?.toInt() ?? 0,
        routedId: (raw['routedId'] as num?)?.toInt() ?? 0,
        routedName: '${raw['routedName'] ?? ''}',
        error: '${raw['error'] ?? ''}',
        bufferMode: UsbBufferMode.fromKey(raw['bufferMode'] as String?),
        bufferFrames: (raw['bufferFrames'] as num?)?.toInt() ?? 0,
        fallback: raw['fallback'] == true,
        details: '${raw['details'] ?? ''}',
      );
    } catch (e) {
      return UsbStartResult(
        ok: false,
        channels: 0,
        routedId: 0,
        routedName: '',
        error: '$e',
      );
    }
  }

  static Future<void> stopPlayback() async {
    try {
      await _ch.invokeMethod<void>('stopUsbPlayback');
    } catch (_) {}
  }

  /// Null when no USB track is running (or not on Android).
  static Future<UsbStats?> stats() async {
    if (!Platform.isAndroid) return null;
    try {
      final raw = await _ch.invokeMethod<dynamic>('usbStats');
      if (raw is! Map || raw['active'] != true) return null;
      return UsbStats(
        underruns: (raw['underruns'] as num?)?.toInt() ?? 0,
        latencyMs: (raw['latencyMs'] as num?)?.toDouble() ?? -1,
        bufferFrames: (raw['bufferFrames'] as num?)?.toInt() ?? 0,
        sampleRate: (raw['sampleRate'] as num?)?.toInt() ?? 0,
        bufferMode: UsbBufferMode.fromKey(raw['bufferMode'] as String?),
        lowLatencyGranted: raw['lowLatencyGranted'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}
