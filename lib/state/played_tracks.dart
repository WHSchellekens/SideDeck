import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// How long a deck has been playing its current track. Fires once when it
/// passes [thresholdSec], so a quick preview never counts as played.
class PlayClock {
  PlayClock({this.thresholdSec = 30});

  final double thresholdSec;
  double _sec = 0;
  bool _fired = false;

  double get seconds => _sec;

  /// Adds [dtSec] of playing time. True exactly once: on the call that
  /// reaches the threshold.
  bool add(double dtSec) {
    if (_fired || dtSec <= 0) return false;
    _sec += dtSec;
    if (_sec >= thresholdSec) {
      _fired = true;
      return true;
    }
    return false;
  }

  /// A new track was loaded.
  void reset() {
    _sec = 0;
    _fired = false;
  }
}

/// Tracks played in the current set, with the time each was played. Kept
/// across app restarts (a crash mid-set loses nothing) until [clear].
class PlayedTracks {
  static const _pref = 'played_tracks';

  final Map<String, int> _at = {};

  int get length => _at.length;
  bool contains(String path) => _at.containsKey(path);

  DateTime? at(String path) {
    final ms = _at[path];
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  int countIn(Iterable<String> paths) => paths.where(_at.containsKey).length;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pref);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final loaded = <String, int>{
        for (final e in decoded.entries)
          if (e.value is num) '${e.key}': (e.value as num).toInt(),
      };
      // Anything marked while loading wins.
      loaded.addAll(_at);
      _at
        ..clear()
        ..addAll(loaded);
    } catch (_) {}
  }

  Future<void> mark(String path, DateTime when) async {
    _at[path] = when.millisecondsSinceEpoch;
    await _save();
  }

  Future<void> clear() async {
    _at.clear();
    await _save();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pref, jsonEncode(_at));
    } catch (_) {}
  }
}

/// "22:04" for a played mark.
String formatPlayedAt(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
