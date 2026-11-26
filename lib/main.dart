import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sidedeck/state/ui_settings.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/ui/home_page.dart';

/// Last Flutter framework error — shown if the normal UI never mounts.
String? bootFatalError;

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // The bundled UI font's license, shown under Settings > Open-source licenses.
  LicenseRegistry.addLicense(() async* {
    final ofl = await rootBundle.loadString('assets/fonts/SpaceGrotesk-OFL.txt');
    yield LicenseEntryWithLineBreaks(const ['Space Grotesk'], ofl);
  });

  // Release/TestFlight: surface errors instead of a blank grey screen.
  ErrorWidget.builder = (details) {
    return Material(
      color: SideDeckTheme.bg,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Text(
            'UI error\n\n${details.exceptionAsString()}\n\n${details.stack}',
            style: const TextStyle(
              color: SideDeckTheme.text,
              fontSize: 13,
              fontFamily: 'Courier',
            ),
          ),
        ),
      ),
    );
  };

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    bootFatalError = '${details.exceptionAsString()}\n${details.stack}';
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    bootFatalError = '$error\n$stack';
    return true;
  };

  runZonedGuarded(
    () => runApp(const SideDeckApp()),
    (error, stack) {
      bootFatalError = '$error\n$stack';
      runApp(_FatalApp(message: bootFatalError!));
    },
  );
}

class SideDeckApp extends StatefulWidget {
  const SideDeckApp({super.key});

  @override
  State<SideDeckApp> createState() => _SideDeckAppState();
}

class _SideDeckAppState extends State<SideDeckApp> {
  final UiSettings _ui = UiSettings();
  late final ThemeData _dark = SideDeckTheme.dark();
  late final ThemeData _outdoor = SideDeckTheme.outdoor();

  @override
  void initState() {
    super.initState();
    _ui.load();
  }

  @override
  void dispose() {
    _ui.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _ui,
      builder: (context, _) => MaterialApp(
        title: 'SideDeck',
        debugShowCheckedModeBanner: false,
        theme: _ui.outdoor ? _outdoor : _dark,
        home: HomePage(ui: _ui),
      ),
    );
  }
}

class _FatalApp extends StatelessWidget {
  const _FatalApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: SideDeckTheme.dark(),
      home: Scaffold(
        backgroundColor: SideDeckTheme.bg,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Text(
              'SideDeck failed to start\n\n$message',
              style: const TextStyle(
                color: SideDeckTheme.text,
                fontSize: 13,
                fontFamily: 'Courier',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
