import 'package:flutter/material.dart';

/// Look taken from the Teenage Engineering EP-136 K.O. Sidekick's screen:
/// black glass, a faint grey cell grid, lit orange for anything switched on,
/// ember for unlit pills, bone and steel greys for content.
class SideDeckTheme {
  /// Space Grotesk (SIL OFL 1.1, assets/fonts): the closest open face to the
  /// Sidekick's own screen font, which is not licensed for redistribution.
  static const fontFamily = 'SpaceGrotesk';

  static const lit = Color(0xFFFF6A21);
  static const ember = Color(0xFF7F2C18);
  static const bone = Color(0xFFE4E3DF);
  static const steel = Color(0xFF989FA5);

  // Dark palette as plain constants, for places without a BuildContext.
  static const bg = Color(0xFF0B0B0C);
  static const panel = Color(0xFF131314);
  static const panelAlt = Color(0xFF1D1E20);
  static const accentA = bone;
  static const accentB = steel;
  static const text = bone;
  static const muted = steel;

  static ThemeData dark() => _build(SideDeckColors.dark);

  static ThemeData _build(SideDeckColors c) {
    final dark = c.brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: lit,
      brightness: c.brightness,
    ).copyWith(
      primary: c.lit,
      onPrimary: Colors.black,
      secondary: c.muted,
      onSecondary: dark ? Colors.black : Colors.white,
      surface: c.panel,
      onSurface: c.text,
      onSurfaceVariant: c.muted,
      outline: c.muted,
    );
    final base = ThemeData(
      brightness: c.brightness,
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: fontFamily,
    );
    return base.copyWith(
      scaffoldBackgroundColor: c.bg,
      canvasColor: c.panel,
      dialogTheme: base.dialogTheme.copyWith(backgroundColor: c.panel),
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: c.bg,
        foregroundColor: c.text,
      ),
      dividerColor: c.cellGrid,
      textTheme: base.textTheme.apply(
        bodyColor: c.text,
        displayColor: c.text,
        fontFamily: fontFamily,
      ),
      extensions: [c],
    );
  }
}

/// The palette every SideDeck screen draws from. Read it with
/// [SideDeckColors.of]; painters get it passed in.
@immutable
class SideDeckColors extends ThemeExtension<SideDeckColors> {
  const SideDeckColors({
    required this.brightness,
    required this.bg,
    required this.screen,
    required this.panel,
    required this.panelAlt,
    required this.text,
    required this.muted,
    required this.played,
    required this.lit,
    required this.unlit,
    required this.pillText,
    required this.deckA,
    required this.deckB,
    required this.waveBody,
    required this.cellGrid,
    required this.beatLine,
    required this.playhead,
    required this.halo,
    required this.stripBg,
    required this.stripBars,
  });

  final Brightness brightness;
  /// Behind and between the decks.
  final Color bg;
  /// The deck lanes (the glass).
  final Color screen;
  /// Bars, rails, the library sheet, dialogs.
  final Color panel;
  /// Fields and raised rows on [panel].
  final Color panelAlt;
  final Color text;
  final Color muted;
  /// Text of tracks you already played.
  final Color played;
  /// Anything switched on, bar lines, markers.
  final Color lit;
  /// Pill that is off.
  final Color unlit;
  /// Label on an unlit pill.
  final Color pillText;
  final Color deckA;
  final Color deckB;
  /// Filled body of the Curve waveform.
  final Color waveBody;
  /// The still grid behind the waveform.
  final Color cellGrid;
  /// Beat lines (not the bar's first beat, which is [lit]).
  final Color beatLine;
  final Color playhead;
  /// Outline that keeps thin lines readable over a waveform.
  final Color halo;
  /// Overview strip above each deck.
  final Color stripBg;
  final Color stripBars;

  Color deck(int i) => i == 0 ? deckA : deckB;

  static const dark = SideDeckColors(
    brightness: Brightness.dark,
    bg: SideDeckTheme.bg,
    screen: Color(0xFF000000),
    panel: SideDeckTheme.panel,
    panelAlt: SideDeckTheme.panelAlt,
    text: SideDeckTheme.bone,
    muted: SideDeckTheme.steel,
    played: Color(0xFF5C6166),
    lit: SideDeckTheme.lit,
    unlit: SideDeckTheme.ember,
    pillText: SideDeckTheme.bone,
    deckA: SideDeckTheme.bone,
    deckB: SideDeckTheme.steel,
    waveBody: SideDeckTheme.ember,
    cellGrid: Color(0xFF1C1D1F),
    beatLine: Color(0x80989FA5),
    playhead: Color(0xFFF4F4F0),
    halo: Color(0xE6000000),
    stripBg: Color(0xFF000000),
    stripBars: Color(0xFF8E9399),
  );

  static SideDeckColors of(BuildContext context) =>
      Theme.of(context).extension<SideDeckColors>() ?? dark;

  @override
  SideDeckColors copyWith() => this;

  /// Palettes switch, they don't fade.
  @override
  SideDeckColors lerp(covariant ThemeExtension<SideDeckColors>? other, double t) {
    if (other is! SideDeckColors) return this;
    return t < 0.5 ? this : other;
  }
}
