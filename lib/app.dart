import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';
import 'features/timer/timer_page.dart';

class TimeTrackerApp extends StatefulWidget {
  const TimeTrackerApp({super.key});

  @override
  State<TimeTrackerApp> createState() => _TimeTrackerAppState();
}

class _TimeTrackerAppState extends State<TimeTrackerApp> {
  AppTheme _currentTheme = AppTheme.defaultDark;
  bool _compactLayout = false;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final themeName = prefs.getString('app_theme') ?? 'defaultDark';
    final compact = prefs.getBool('compact_layout') ?? false;

    setState(() {
      _currentTheme = AppTheme.values.firstWhere(
        (t) => t.name == themeName,
        orElse: () => AppTheme.defaultDark,
      );
      _compactLayout = compact;
      _initialized = true;
    });
  }

  Future<void> _updateTheme(AppTheme theme) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_theme', theme.name);
    setState(() => _currentTheme = theme);
  }

  Future<void> _updateLayout(bool compact) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('compact_layout', compact);
    setState(() => _compactLayout = compact);
  }

  ThemeData _buildTheme() {
    switch (_currentTheme) {
      case AppTheme.focus:
        return ThemeData.dark().copyWith(
          scaffoldBackgroundColor: const Color(0xFF141622),
          primaryColor: const Color(0xFF64FFDA),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF64FFDA),
            secondary: Color(0xFF64FFDA),
          ),
        );
      case AppTheme.highContrast:
        return ThemeData.dark().copyWith(
          scaffoldBackgroundColor: Colors.black,
          primaryColor: Colors.yellowAccent,
          colorScheme: const ColorScheme.dark(
            primary: Colors.yellowAccent,
            secondary: Colors.yellowAccent,
          ),
          textTheme: ThemeData.dark().textTheme.apply(
            bodyColor: Colors.white,
            displayColor: Colors.white,
          ),
        );
      case AppTheme.oledBlack:
        return ThemeData.dark().copyWith(
          scaffoldBackgroundColor: Colors.black,
          primaryColor: const Color(0xFF00E5FF),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF00E5FF),
            secondary: Color(0xFF00E5FF),
          ),
        );
      case AppTheme.defaultDark:
        return ThemeData.dark().copyWith(
          scaffoldBackgroundColor: const Color(0xFF0F111A),
          primaryColor: const Color(0xFF00E5FF),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(),
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: TimerPage(
        compactLayout: _compactLayout,
        currentTheme: _currentTheme,
        onThemeChanged: _updateTheme,
        onLayoutChanged: _updateLayout,
      ),
    );
  }
}

