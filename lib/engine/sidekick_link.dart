import 'dart:io';

import 'package:flutter/services.dart';

/// One MIDI message from the external mixer (or a device change).
class SidekickMidiEvent {
  const SidekickMidiEvent({
    required this.kind,
    this.channel = 0,
    this.number = 0,
    this.value = 0,
    this.name = '',
  });

  /// `cc`, `bend`, `noteOn`, `noteOff`, `program`, or `device` (a MIDI port
  /// opened or went away; [name] is empty when it went away).
  final String kind;
  /// MIDI channel, 0-based: 0 and 1 are the Sidekick's channels 1 and 2.
  final int channel;
  /// CC or note number.
  final int number;
  /// CC value 0..127, or pitch bend -8192..8191.
  final int value;
  final String name;

  bool get isDevice => kind == 'device';

  String describe() {
    final ch = 'ch${channel + 1}';
    return switch (kind) {
      'cc' => '$ch  CC $number = $value',
      'bend' => '$ch  bend $value',
      'noteOn' => '$ch  note $number on ($value)',
      'noteOff' => '$ch  note $number off',
      'program' => '$ch  program $number',
      _ => name.isEmpty ? 'MIDI device gone' : 'MIDI device: $name',
    };
  }
}

class SidekickListenResult {
  const SidekickListenResult({
    required this.ok,
    required this.channels,
    required this.device,
    required this.error,
  });

  final bool ok;
  /// USB input channels Android opened (8 includes the master on 7-8).
  final int channels;
  final String device;
  final String error;
}

/// Read-only links back from the external mixer (Android only): its MIDI
/// output, and listening to its USB inputs (7-8 carry the master output).
class SidekickLink {
  static const _ch = MethodChannel('sidedeck/audio');
  static const _midi = EventChannel('sidedeck/midi');
  static Stream<SidekickMidiEvent>? _stream;

  static Stream<SidekickMidiEvent> midi() {
    if (!Platform.isAndroid) return const Stream.empty();
    return _stream ??= _midi.receiveBroadcastStream().map((raw) {
      final m = raw is Map ? raw : const {};
      return SidekickMidiEvent(
        kind: '${m['kind'] ?? ''}',
        channel: (m['channel'] as num?)?.toInt() ?? 0,
        number: (m['number'] as num?)?.toInt() ?? 0,
        value: (m['value'] as num?)?.toInt() ?? 0,
        name: '${m['name'] ?? ''}',
      );
    });
  }

  /// Starts capturing the USB inputs into the engine. Needs the microphone
  /// permission (the caller asks for it first).
  static Future<SidekickListenResult> startListening(int engineHandle) async {
    if (!Platform.isAndroid) {
      return const SidekickListenResult(
        ok: false,
        channels: 0,
        device: '',
        error: 'Only on Android',
      );
    }
    try {
      final raw = await _ch.invokeMethod<dynamic>('startSidekickListen', {
        'handle': engineHandle,
      });
      final m = raw is Map ? raw : const {};
      return SidekickListenResult(
        ok: m['ok'] == true,
        channels: (m['channels'] as num?)?.toInt() ?? 0,
        device: '${m['device'] ?? ''}',
        error: '${m['error'] ?? ''}',
      );
    } catch (e) {
      return SidekickListenResult(ok: false, channels: 0, device: '', error: '$e');
    }
  }

  static Future<void> stopListening() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<void>('stopSidekickListen');
    } catch (_) {}
  }
}
