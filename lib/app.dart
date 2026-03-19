import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'features/timer/timer_page.dart';

class TimeTrackerApp extends StatefulWidget {
  const TimeTrackerApp({super.key});

  @override
  State<TimeTrackerApp> createState() => _TimeTrackerAppState();
}

class _TimeTrackerAppState extends State<TimeTrackerApp> {
  bool _compactLayout = false;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final compact = prefs.getBool('compact_layout') ?? false;
    setState(() {
      _compactLayout = compact;
      _initialized = true;
    });
  }

  Future<void> _updateLayout(bool compact) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('compact_layout', compact);
    setState(() => _compactLayout = compact);
  }

  static ThemeData _lightTheme() {
    const primary = Color(0xFF09090B);
    return ThemeData(
      useMaterial3: true,
      colorScheme: const ColorScheme.light(
        primary: primary,
        onPrimary: Colors.white,
        primaryContainer: Color(0xFFF4F4F5),
        onPrimaryContainer: primary,
        surface: Colors.white,
        onSurface: primary,
        error: Color(0xFFDC2626),
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: Colors.white,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: primary,
      ),
    );
  }

  static ThemeData _darkTheme() {
    const primary = Color(0xFFFAFAFA);
    const surface = Color(0xFF09090B);
    return ThemeData(
      useMaterial3: true,
      colorScheme: const ColorScheme.dark(
        primary: primary,
        onPrimary: surface,
        primaryContainer: Color(0xFF27272A),
        onPrimaryContainer: primary,
        surface: surface,
        onSurface: primary,
        error: Color(0xFFEF4444),
        onError: surface,
      ),
      scaffoldBackgroundColor: surface,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: primary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _lightTheme(),
        darkTheme: _darkTheme(),
        themeMode: ThemeMode.system,
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _lightTheme(),
      darkTheme: _darkTheme(),
      themeMode: ThemeMode.system,
      home: TimerPage(
        compactLayout: _compactLayout,
        onLayoutChanged: _updateLayout,
      ),
    );
  }
}
