import 'dart:async';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Timezones for notifications
  tz.initializeTimeZones();

  runApp(const TimeTrackerApp());
}

class TimeTrackerApp extends StatelessWidget {
  const TimeTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F111A),
        primaryColor: const Color(0xFF00E5FF),
      ),
      home: const TimerPage(),
    );
  }
}

class TimerPage extends StatefulWidget {
  const TimerPage({super.key});

  @override
  State<TimerPage> createState() => _TimerPageState();
}

class _TimerPageState extends State<TimerPage> {
  final TextEditingController _hoursController = TextEditingController();
  final TextEditingController _minutesController = TextEditingController();
  final TextEditingController _notifyBeforeController = TextEditingController();
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  TimeOfDay _checkInTime = TimeOfDay.now();
  Timer? _timer;
  Duration _timeLeft = Duration.zero;
  double _progress = 0.0;
  bool _isRunning = false;
  DateTime? _exitTime;

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _loadSavedData();
  }

  // --- Notification Logic ---
  Future<void> _initNotifications() async {
    final androidImplementation = _notificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    // Request notification permission
    await androidImplementation?.requestNotificationsPermission();

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings();
    await _notificationsPlugin.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
    );
  }

  Future<void> _requestExactAlarmPermission() async {
    if (!Platform.isAndroid) return;

    try {
      final intent = AndroidIntent(
        action: 'android.settings.REQUEST_SCHEDULE_EXACT_ALARM',
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );
      await intent.launch();
    } catch (e) {
      debugPrint('Failed to open exact alarm settings: $e');
    }
  }

  // Get total duration in minutes from hours and minutes inputs
  int _getDurationInMinutes() {
    final hours = int.tryParse(_hoursController.text) ?? 0;
    final minutes = int.tryParse(_minutesController.text) ?? 0;
    return hours * 60 + minutes;
  }

  Future<void> _scheduleNotification(
    DateTime scheduledTime, {
    bool isEarlyWarning = false,
    int minutesBefore = 0,
  }) async {
    if (scheduledTime.isBefore(DateTime.now())) return;

    final title = isEarlyWarning ? 'Shift Ending Soon!' : 'Work Day Complete!';
    final body = isEarlyWarning
        ? 'Your shift ends in $minutesBefore minute${minutesBefore == 1 ? '' : 's'}. Time to wrap up!'
        : 'You have reached your target hours. Time to head out!';

    final notificationDetails = NotificationDetails(
      android: AndroidNotificationDetails(
        'timer_channel',
        'Shift Tracking',
        importance: Importance.max,
        priority: Priority.high,
        color: Color(0xFF00E5FF),
      ),
    );

    // Use different notification IDs: 0 for end time, 1 for early warning
    final notificationId = isEarlyWarning ? 1 : 0;

    // Try to schedule with exact alarms first (most accurate)
    try {
      await _notificationsPlugin.zonedSchedule(
        notificationId,
        title,
        body,
        tz.TZDateTime.from(scheduledTime, tz.local),
        notificationDetails,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    } on PlatformException catch (e) {
      // If exact alarms are not permitted, fall back to inexact alarms
      if (e.code == 'exact_alarms_not_permitted') {
        // Try to request the permission (opens system settings)
        _requestExactAlarmPermission();

        // Fall back to inexact alarms for now
        try {
          await _notificationsPlugin.zonedSchedule(
            notificationId,
            title,
            body,
            tz.TZDateTime.from(scheduledTime, tz.local),
            notificationDetails,
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          );
        } catch (fallbackError) {
          debugPrint(
            'Failed to schedule notification (inexact): $fallbackError',
          );
        }
      } else {
        // For other errors, try inexact as fallback
        try {
          await _notificationsPlugin.zonedSchedule(
            notificationId,
            title,
            body,
            tz.TZDateTime.from(scheduledTime, tz.local),
            notificationDetails,
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          );
        } catch (fallbackError) {
          debugPrint('Failed to schedule notification: $fallbackError');
        }
      }
    } catch (e) {
      // Catch any other exceptions and try inexact as fallback
      try {
        await _notificationsPlugin.zonedSchedule(
          notificationId,
          title,
          body,
          tz.TZDateTime.from(scheduledTime, tz.local),
          notificationDetails,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      } catch (fallbackError) {
        debugPrint('Failed to schedule notification: $fallbackError');
      }
    }
  }

  // --- Persistence Logic ---
  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _hoursController.text = prefs.getString('target_hours') ?? "8";
      _minutesController.text = prefs.getString('target_minutes') ?? "0";
      _notifyBeforeController.text = prefs.getString('notify_before') ?? "0";
      final h = prefs.getInt('checkin_hour') ?? TimeOfDay.now().hour;
      final m = prefs.getInt('checkin_minute') ?? TimeOfDay.now().minute;
      _checkInTime = TimeOfDay(hour: h, minute: m);
    });

    // Restore active session if it exists
    await _restoreSession();
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final exitTimeMillis = prefs.getInt('exit_time');
    final wasRunning = prefs.getBool('is_running') ?? false;

    if (exitTimeMillis != null && wasRunning) {
      final savedExitTime = DateTime.fromMillisecondsSinceEpoch(exitTimeMillis);
      final now = DateTime.now();

      // Check if session is still valid (not expired)
      if (savedExitTime.isAfter(now)) {
        setState(() {
          _exitTime = savedExitTime;
          _isRunning = true;
        });
        _resumeTimer();
      } else {
        // Session expired, clear it
        await _clearSession();
      }
    }
  }

  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('target_hours', _hoursController.text);
    await prefs.setString('target_minutes', _minutesController.text);
    await prefs.setString('notify_before', _notifyBeforeController.text);
    await prefs.setInt('checkin_hour', _checkInTime.hour);
    await prefs.setInt('checkin_minute', _checkInTime.minute);
  }

  Future<void> _saveSession() async {
    final prefs = await SharedPreferences.getInstance();
    if (_exitTime != null) {
      await prefs.setInt('exit_time', _exitTime!.millisecondsSinceEpoch);
      await prefs.setBool('is_running', _isRunning);
    }
  }

  Future<void> _clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('exit_time');
    await prefs.setBool('is_running', false);
  }

  // --- Timer Calculation ---
  void _startTracking() {
    if (_isRunning) {
      _stopTracking();
      return;
    }

    _saveData();
    _timer?.cancel();

    final now = DateTime.now();
    final targetMinutes = _getDurationInMinutes();
    final checkInDateTime = DateTime(
      now.year,
      now.month,
      now.day,
      _checkInTime.hour,
      _checkInTime.minute,
    );
    final exitTime = checkInDateTime.add(Duration(minutes: targetMinutes));

    _exitTime = exitTime;
    _isRunning = true;
    _saveSession();

    // Schedule notification with notify before offset
    final notifyBeforeMinutes = int.tryParse(_notifyBeforeController.text) ?? 0;

    if (notifyBeforeMinutes > 0) {
      // Schedule early warning notification
      final earlyNotificationTime = exitTime.subtract(
        Duration(minutes: notifyBeforeMinutes),
      );
      _scheduleNotification(
        earlyNotificationTime,
        isEarlyWarning: true,
        minutesBefore: notifyBeforeMinutes,
      );
    }

    // Always schedule end time notification
    _scheduleNotification(exitTime, isEarlyWarning: false);

    _resumeTimer();
  }

  void _stopTracking() {
    _timer?.cancel();
    setState(() {
      _isRunning = false;
      _exitTime = null;
      _timeLeft = Duration.zero;
      _progress = 0.0;
    });
    _clearSession();
    // Cancel both scheduled notifications
    _notificationsPlugin.cancel(0);
    _notificationsPlugin.cancel(1);
  }

  void _resumeTimer() {
    if (_exitTime == null) return;

    final targetMinutes = _getDurationInMinutes();
    final totalDurationSeconds = targetMinutes * 60.0;

    // Update UI immediately
    _updateTimerState(targetMinutes, totalDurationSeconds);

    // Then update every second
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _updateTimerState(targetMinutes, totalDurationSeconds);
    });
  }

  void _updateTimerState(int targetMinutes, double totalDurationSeconds) {
    if (_exitTime == null) return;

    final currentTime = DateTime.now();
    final remaining = _exitTime!.difference(currentTime);

    setState(() {
      if (remaining.isNegative) {
        _timeLeft = Duration.zero;
        _progress = 1.0;
        _isRunning = false;
        _timer?.cancel();
        _clearSession();
      } else {
        _timeLeft = remaining;
        _progress = 1.0 - (remaining.inSeconds / totalDurationSeconds);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1A1C2C), Color(0xFF0F111A)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Column(
              children: [
                const SizedBox(height: 40),
                const Text(
                  "Shift Timer",
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const Text(
                  "Track your remaining time",
                  style: TextStyle(color: Colors.white54),
                ),
                const Spacer(),

                // Visual Countdown Ring
                Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      height: 280,
                      width: 280,
                      child: CircularProgressIndicator(
                        value: _progress.clamp(0.0, 1.0),
                        strokeWidth: 15,
                        strokeCap: StrokeCap.round,
                        backgroundColor: Colors.white10,
                        color: const Color(0xFF00E5FF),
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          "${_timeLeft.inHours}:${(_timeLeft.inMinutes % 60).toString().padLeft(2, '0')}:${(_timeLeft.inSeconds % 60).toString().padLeft(2, '0')}",
                          style: const TextStyle(
                            fontSize: 48,
                            fontWeight: FontWeight.w200,
                            fontFamily: 'monospace',
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _isRunning ? "REMAINING" : "READY",
                          style: const TextStyle(
                            color: Colors.cyanAccent,
                            letterSpacing: 4,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (_isRunning && _exitTime != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            "Ends at ${_formatTime(_exitTime!)}",
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),

                const Spacer(),

                // Settings Cards - Row 1
                Row(
                  children: [
                    _buildInputCard(
                      "CHECK-IN",
                      _checkInTime.format(context),
                      icon: Icons.access_time,
                      onTap: _isRunning
                          ? null
                          : () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: _checkInTime,
                              );
                              if (picked != null)
                                setState(() => _checkInTime = picked);
                            },
                    ),
                    const SizedBox(width: 20),
                    _buildInputCard(
                      "HOURS",
                      "${_hoursController.text.isEmpty ? '8' : _hoursController.text}h",
                      icon: Icons.timer_outlined,
                      isTextField: true,
                      textController: _hoursController,
                      hintText: "8",
                      isNumericOnly: true,
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                // Settings Cards - Row 2
                Row(
                  children: [
                    _buildInputCard(
                      "MINUTES",
                      "${_minutesController.text.isEmpty ? '0' : _minutesController.text} min",
                      icon: Icons.timer,
                      isTextField: true,
                      textController: _minutesController,
                      hintText: "0",
                      isNumericOnly: true,
                    ),
                    const SizedBox(width: 20),
                    _buildInputCard(
                      "NOTIFY BEFORE",
                      "${_notifyBeforeController.text.isEmpty ? '0' : _notifyBeforeController.text} min",
                      icon: Icons.notifications_active,
                      isTextField: true,
                      textController: _notifyBeforeController,
                      hintText: "0",
                      isNumericOnly: true,
                    ),
                  ],
                ),

                const SizedBox(height: 30),

                // Main Button
                ElevatedButton(
                  onPressed: _startTracking,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isRunning
                        ? Colors.red.withOpacity(0.8)
                        : const Color(0xFF00E5FF),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 65),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    elevation: 10,
                    shadowColor:
                        (_isRunning ? Colors.red : const Color(0xFF00E5FF))
                            .withOpacity(0.4),
                  ),
                  child: Text(
                    _isRunning ? "STOP SESSION" : "START SESSION",
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInputCard(
    String label,
    String value, {
    required IconData icon,
    VoidCallback? onTap,
    bool isTextField = false,
    TextEditingController? textController,
    String? hintText,
    bool isNumericOnly = false,
  }) {
    final isDisabled = _isRunning && (onTap != null || isTextField);
    return Expanded(
      child: GestureDetector(
        onTap: isDisabled ? null : onTap,
        child: Opacity(
          opacity: isDisabled ? 0.5 : 1.0,
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 20, color: Colors.cyanAccent),
                const SizedBox(height: 12),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                isTextField
                    ? TextField(
                        controller: textController,
                        enabled: !_isRunning,
                        keyboardType: isNumericOnly
                            ? TextInputType.number
                            : const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                        inputFormatters: isNumericOnly
                            ? [FilteringTextInputFormatter.digitsOnly]
                            : null,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: hintText ?? "0.0",
                          hintStyle: const TextStyle(color: Colors.white38),
                        ),
                      )
                    : Text(
                        value,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour;
    final minute = dateTime.minute;
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
    return '${displayHour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} $period';
  }

  @override
  void dispose() {
    _timer?.cancel();
    _hoursController.dispose();
    _minutesController.dispose();
    _notifyBeforeController.dispose();
    super.dispose();
  }
}
