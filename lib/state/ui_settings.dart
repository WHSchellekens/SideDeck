import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How the scrolling waveform is drawn (Settings > Display > Waveform).
enum WaveStyle {
  /// Vertical lines in the deck colour, fainter when quiet.
  solid('solid', 'Solid'),
  /// Lit cells, like the Sidekick's dot-matrix screen.
  dots('dots', 'Dot matrix'),
  /// Filled body with a line tracing the peaks, like the Sidekick's EQ graph.
  curve('curve', 'Curve');

  const WaveStyle(this.key, this.label);

  final String key;
  final String label;

  static WaveStyle fromKey(String? key) =>
      values.firstWhere((s) => s.key == key, orElse: () => solid);
}

/// Display settings, stored like the other settings.
class UiSettings extends ChangeNotifier {
  static const _waveStylePref = 'wave_style';
  static const _outdoorPref = 'outdoor_mode';

  WaveStyle waveStyle = WaveStyle.solid;
  /// Light screen for daylight. Dark is the default.
  bool outdoor = false;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      waveStyle = WaveStyle.fromKey(prefs.getString(_waveStylePref));
      outdoor = prefs.getBool(_outdoorPref) ?? false;
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setOutdoor(bool enabled) async {
    if (outdoor == enabled) return;
    outdoor = enabled;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_outdoorPref, enabled);
    } catch (_) {}
  }

  Future<void> setWaveStyle(WaveStyle style) async {
    if (waveStyle == style) return;
    waveStyle = style;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_waveStylePref, style.key);
    } catch (_) {}
  }
}
