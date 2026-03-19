import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:workmanager/workmanager.dart';

import '../stats/stats_page.dart';

class TimerPage extends StatefulWidget {
  const TimerPage({
    super.key,
    required this.compactLayout,
    required this.onLayoutChanged,
  });

  final bool compactLayout;
  final ValueChanged<bool> onLayoutChanged;

  @override
  State<TimerPage> createState() => _TimerPageState();
}

class _TimerPageState extends State<TimerPage> {
  final TextEditingController _hoursController = TextEditingController();
  final TextEditingController _minutesController = TextEditingController();
  final TextEditingController _notifyBeforeController = TextEditingController();
  final TextEditingController _perimeterController = TextEditingController();
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  TimeOfDay _checkInTime = TimeOfDay.now();
  Timer? _timer;
  Timer? _locationCheckTimer;
  Duration _timeLeft = Duration.zero;
  double _progress = 0.0;
  bool _isRunning = false;
  DateTime? _exitTime;
  DateTime? _sessionStartTime;

  bool _hadPositiveRemaining = false;

  // Geofencing variables
  Position? _geofenceLocation;
  double _geofenceRadius = 250.0;
  bool _geofenceEnabled = false;
  bool _isInsideGeofence = false;
  StreamSubscription<Position>? _positionStreamSubscription;

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _loadSavedData();
    _initGeofencing();
  }

  // --- Notification Logic ---
  Future<void> _initNotifications() async {
    final androidImplementation = _notificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    await androidImplementation?.requestNotificationsPermission();

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings();
    await _notificationsPlugin.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final actionId = response.actionId;
        final payload = response.payload ?? '';

        if (actionId == 'start_session' || payload == 'start_session') {
          if (!_isRunning) _startTracking();
          return;
        }

        if (actionId == 'extend_30' || payload == 'extend_30') {
          _extendCurrentSession(const Duration(minutes: 30));
          return;
        }
      },
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

    final androidDetails = AndroidNotificationDetails(
      isEarlyWarning ? 'shift_warning_channel' : 'shift_end_channel',
      isEarlyWarning ? 'Shift Early Warning' : 'Shift End',
      importance: Importance.max,
      priority: Priority.high,
      actions: isEarlyWarning
          ? <AndroidNotificationAction>[
              const AndroidNotificationAction(
                'extend_30',
                'Extend by 30 min',
                showsUserInterface: true,
                cancelNotification: true,
              ),
            ]
          : null,
    );

    final notificationDetails = NotificationDetails(android: androidDetails);
    final notificationId = isEarlyWarning ? 1 : 0;

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
      if (e.code == 'exact_alarms_not_permitted') {
        _requestExactAlarmPermission();
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
          debugPrint('Failed to schedule notification (inexact): $fallbackError');
        }
      } else {
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

  // --- Geofencing Logic ---
  Future<void> _initGeofencing() async {
    if (_geofenceEnabled && _geofenceLocation != null) {
      await _startLocationMonitoring();
    }
  }

  Future<bool> _requestLocationPermissions() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Location services are disabled. Please enable them.'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Location permissions are denied.'),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
        }
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Location permissions are permanently denied. Please enable them in settings.',
            ),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
      return false;
    }

    if (Platform.isAndroid) {
      final backgroundPermission = await Permission.locationAlways.status;
      if (backgroundPermission.isDenied) {
        await Permission.locationAlways.request();
      }
    }

    return true;
  }

  Future<void> _setCurrentLocationAsGeofence() async {
    final hasPermission = await _requestLocationPermissions();
    if (!hasPermission) return;

    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      setState(() {
        _geofenceLocation = position;
        _geofenceEnabled = true;
      });

      await _saveData();
      await _startLocationMonitoring();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Location set! Geofencing is now active.'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error getting location: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error getting location: $e'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    }
  }

  Future<void> _startLocationMonitoring() async {
    if (!_geofenceEnabled || _geofenceLocation == null) return;

    final hasPermission = await _requestLocationPermissions();
    if (!hasPermission) {
      setState(() => _geofenceEnabled = false);
      await _saveData();
      return;
    }

    await _stopLocationMonitoring();

    LocationSettings locationSettings;
    if (Platform.isAndroid) {
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationText: 'Monitoring location for geofencing',
          notificationTitle: 'Time Remaining',
          enableWakeLock: true,
        ),
      );
    } else {
      locationSettings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      );
    }

    _positionStreamSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (Position position) => _checkGeofenceStatus(position),
      onError: (error) => debugPrint('Location stream error: $error'),
    );

    await Workmanager().registerPeriodicTask(
      'geofence-check',
      'geofenceCheck',
      frequency: const Duration(minutes: 15),
      constraints: Constraints(
        networkType: NetworkType.notRequired,
        requiresBatteryNotLow: false,
        requiresCharging: false,
        requiresDeviceIdle: false,
        requiresStorageNotLow: false,
      ),
    );
  }

  Future<void> _stopLocationMonitoring() async {
    await _positionStreamSubscription?.cancel();
    _positionStreamSubscription = null;
    await Workmanager().cancelByUniqueName('geofence-check');
  }

  void _checkGeofenceStatus(Position currentPosition) async {
    if (_geofenceLocation == null) return;

    final distance = Geolocator.distanceBetween(
      _geofenceLocation!.latitude,
      _geofenceLocation!.longitude,
      currentPosition.latitude,
      currentPosition.longitude,
    );

    final isInside = distance <= _geofenceRadius;

    if (isInside && !_isInsideGeofence) {
      _isInsideGeofence = true;

      final prefs = await SharedPreferences.getInstance();
      final isSessionRunning = prefs.getBool('is_running') ?? false;

      final now = DateTime.now().millisecondsSinceEpoch;
      final lastNotificationTime = prefs.getInt('last_geofence_notification_time');
      final shouldNotify =
          lastNotificationTime == null ||
          (now - lastNotificationTime) >= 5 * 60 * 1000;

      if (!isSessionRunning && shouldNotify) {
        await _sendGeofenceNotification();
        await prefs.setInt('last_geofence_notification_time', now);
      }
    } else if (!isInside && _isInsideGeofence) {
      _isInsideGeofence = false;
    }
  }

  Future<void> _sendGeofenceNotification() async {
    const androidDetails = AndroidNotificationDetails(
      'geofence_channel',
      'Geofence Alerts',
      importance: Importance.max,
      priority: Priority.high,
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction(
          'start_session',
          'Start session now',
          showsUserInterface: true,
          cancelNotification: true,
        ),
      ],
    );

    const notificationDetails = NotificationDetails(android: androidDetails);

    await _notificationsPlugin.show(
      2,
      'Time to Punch In!',
      'You\'ve arrived at your location. Tap to open the app and start your session.',
      notificationDetails,
    );
  }

  Future<void> _updatePerimeter() async {
    final perimeter = double.tryParse(_perimeterController.text);
    if (perimeter != null && perimeter > 0) {
      setState(() => _geofenceRadius = perimeter);
      await _saveData();
      if (_geofenceEnabled && _geofenceLocation != null) {
        await _startLocationMonitoring();
      }
    }
  }

  // --- Session Helpers ---
  void _extendCurrentSession(Duration delta) {
    if (_exitTime == null || !_isRunning) return;

    final newExitTime = _exitTime!.add(delta);
    _exitTime = newExitTime;
    _saveSession();

    _notificationsPlugin.cancel(0);
    _notificationsPlugin.cancel(1);

    final notifyBeforeMinutes = int.tryParse(_notifyBeforeController.text) ?? 0;

    if (notifyBeforeMinutes > 0) {
      _scheduleNotification(
        newExitTime.subtract(Duration(minutes: notifyBeforeMinutes)),
        isEarlyWarning: true,
        minutesBefore: notifyBeforeMinutes,
      );
    }

    _scheduleNotification(newExitTime, isEarlyWarning: false);
    _resumeTimer();
  }

  Future<void> _recordCompletedSession(
    DateTime sessionStart,
    DateTime sessionEnd,
  ) async {
    if (!sessionEnd.isAfter(sessionStart)) return;

    final workedMinutes = sessionEnd.difference(sessionStart).inMinutes;
    if (workedMinutes <= 0) return;

    final dateKey = _formatDateKey(sessionStart);
    final prefs = await SharedPreferences.getInstance();

    final existingJson = prefs.getString('daily_totals');
    Map<String, dynamic> decoded =
        existingJson != null && existingJson.isNotEmpty
        ? jsonDecode(existingJson) as Map<String, dynamic>
        : <String, dynamic>{};

    final currentMinutes = (decoded[dateKey] as int?) ?? 0;
    decoded[dateKey] = currentMinutes + workedMinutes;
    await prefs.setString('daily_totals', jsonEncode(decoded));

    final checkinJson = prefs.getString('daily_first_checkin');
    Map<String, dynamic> decodedCheckin =
        checkinJson != null && checkinJson.isNotEmpty
        ? jsonDecode(checkinJson) as Map<String, dynamic>
        : <String, dynamic>{};

    decodedCheckin.putIfAbsent(dateKey, () => sessionStart.millisecondsSinceEpoch);
    await prefs.setString('daily_first_checkin', jsonEncode(decodedCheckin));
  }

  String _formatDateKey(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  Future<void> _toggleGeofence() async {
    if (_geofenceLocation == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Please set a location first.'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
      return;
    }

    setState(() => _geofenceEnabled = !_geofenceEnabled);
    await _saveData();

    if (_geofenceEnabled) {
      await _startLocationMonitoring();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Geofencing enabled.'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } else {
      await _stopLocationMonitoring();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Geofencing disabled.'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    }
  }

  // --- Persistence ---
  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _hoursController.text = prefs.getString('target_hours') ?? '8';
      _minutesController.text = prefs.getString('target_minutes') ?? '0';
      _notifyBeforeController.text = prefs.getString('notify_before') ?? '0';
      final h = prefs.getInt('checkin_hour') ?? TimeOfDay.now().hour;
      final m = prefs.getInt('checkin_minute') ?? TimeOfDay.now().minute;
      _checkInTime = TimeOfDay(hour: h, minute: m);

      final lat = prefs.getDouble('geofence_latitude');
      final lon = prefs.getDouble('geofence_longitude');
      if (lat != null && lon != null) {
        _geofenceLocation = Position(
          latitude: lat,
          longitude: lon,
          timestamp: DateTime.now(),
          accuracy: 0,
          altitude: 0,
          altitudeAccuracy: 0,
          heading: 0,
          headingAccuracy: 0,
          speed: 0,
          speedAccuracy: 0,
        );
      }
      _geofenceRadius = prefs.getDouble('geofence_radius') ?? 250.0;
      _perimeterController.text = _geofenceRadius.toInt().toString();
      _geofenceEnabled = prefs.getBool('geofence_enabled') ?? false;
    });

    await _restoreSession();
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final exitTimeMillis = prefs.getInt('exit_time');
    final wasRunning = prefs.getBool('is_running') ?? false;
    final startTimeMillis = prefs.getInt('session_start_time');

    if (exitTimeMillis != null && wasRunning) {
      final savedExitTime = DateTime.fromMillisecondsSinceEpoch(exitTimeMillis);
      final now = DateTime.now();

      if (savedExitTime.isAfter(now)) {
        setState(() {
          _exitTime = savedExitTime;
          _isRunning = true;
          if (startTimeMillis != null) {
            _sessionStartTime = DateTime.fromMillisecondsSinceEpoch(startTimeMillis);
          }
        });
        _resumeTimer();
      } else {
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

    if (_geofenceLocation != null) {
      await prefs.setDouble('geofence_latitude', _geofenceLocation!.latitude);
      await prefs.setDouble('geofence_longitude', _geofenceLocation!.longitude);
    }
    await prefs.setDouble('geofence_radius', _geofenceRadius);
    await prefs.setBool('geofence_enabled', _geofenceEnabled);
  }

  Future<void> _saveSession() async {
    final prefs = await SharedPreferences.getInstance();
    if (_exitTime != null) {
      await prefs.setInt('exit_time', _exitTime!.millisecondsSinceEpoch);
      await prefs.setBool('is_running', _isRunning);
      if (_sessionStartTime != null) {
        await prefs.setInt(
          'session_start_time',
          _sessionStartTime!.millisecondsSinceEpoch,
        );
      }
    }
  }

  Future<void> _clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('exit_time');
    await prefs.remove('session_start_time');
    await prefs.setBool('is_running', false);
  }

  // --- Timer ---
  void _startTracking() {
    if (_isRunning) {
      _stopTracking();
      return;
    }

    _saveData();
    _timer?.cancel();

    final now = DateTime.now();
    final targetMinutes = _getDurationInMinutes();
    if (targetMinutes <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Enter a positive shift length (hours or minutes).'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
      return;
    }

    final checkInDateTime = DateTime(
      now.year,
      now.month,
      now.day,
      _checkInTime.hour,
      _checkInTime.minute,
    );
    final exitTime = checkInDateTime.add(Duration(minutes: targetMinutes));

    if (!exitTime.isAfter(now)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Shift end time has already passed. Set a later check-in or shorter duration.',
            ),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
      return;
    }

    _sessionStartTime = exitTime.subtract(Duration(minutes: targetMinutes));
    _exitTime = exitTime;
    _hadPositiveRemaining = false;
    _isRunning = true;
    _saveSession();

    final notifyBeforeMinutes = int.tryParse(_notifyBeforeController.text) ?? 0;
    if (notifyBeforeMinutes > 0) {
      _scheduleNotification(
        exitTime.subtract(Duration(minutes: notifyBeforeMinutes)),
        isEarlyWarning: true,
        minutesBefore: notifyBeforeMinutes,
      );
    }

    _scheduleNotification(exitTime, isEarlyWarning: false);
    _resumeTimer();
  }

  void _stopTracking() {
    _timer?.cancel();
    final now = DateTime.now();
    final start = _sessionStartTime ?? now;
    _recordCompletedSession(start, now);
    setState(() {
      _isRunning = false;
      _exitTime = null;
      _timeLeft = Duration.zero;
      _progress = 0.0;
    });
    _clearSession();
    _notificationsPlugin.cancel(0);
    _notificationsPlugin.cancel(1);
  }

  void _resumeTimer() {
    if (_exitTime == null) return;

    final targetMinutes = _getDurationInMinutes();
    final totalDurationSeconds = targetMinutes * 60.0;

    _updateTimerState(targetMinutes, totalDurationSeconds);

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _updateTimerState(targetMinutes, totalDurationSeconds);
    });
  }

  void _updateTimerState(int targetMinutes, double totalDurationSeconds) {
    if (_exitTime == null) return;

    final remaining = _exitTime!.difference(DateTime.now());

    setState(() {
      if (remaining.isNegative) {
        _timeLeft = Duration.zero;
        _progress = 1.0;
        _isRunning = false;
        _timer?.cancel();
        if (_hadPositiveRemaining) {
          final start = _sessionStartTime ?? _exitTime!;
          _recordCompletedSession(start, _exitTime!);
        }
        _clearSession();
      } else {
        _hadPositiveRemaining = true;
        _timeLeft = remaining;
        _progress = 1.0 - (remaining.inSeconds / totalDurationSeconds);
      }
    });
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
    _locationCheckTimer?.cancel();
    _positionStreamSubscription?.cancel();
    _hoursController.dispose();
    _minutesController.dispose();
    _notifyBeforeController.dispose();
    _perimeterController.dispose();
    super.dispose();
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isCompact = widget.compactLayout;
    final ringSize = isCompact ? 200.0 : 256.0;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
          children: [
            // ── Header ───────────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Time Shield',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                        color: cs.onSurface,
                      ),
                    ),
                    Text(
                      'Track your remaining time',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.45),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.bar_chart_outlined),
                      color: cs.onSurface.withValues(alpha: 0.6),
                      tooltip: 'View stats',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const StatsPage()),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.tune_outlined),
                      color: cs.onSurface.withValues(alpha: 0.6),
                      tooltip: 'Preferences',
                      onPressed: () => _showPreferencesSheet(context),
                    ),
                  ],
                ),
              ],
            ),

            SizedBox(height: isCompact ? 24.0 : 36.0),

            // ── Circular ring ────────────────────────────────────────────
            Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    height: ringSize,
                    width: ringSize,
                    child: CircularProgressIndicator(
                      value: _progress.clamp(0.0, 1.0),
                      strokeWidth: 3,
                      strokeCap: StrokeCap.round,
                      backgroundColor: cs.primary.withValues(alpha: 0.12),
                      valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${_timeLeft.inHours}:${(_timeLeft.inMinutes % 60).toString().padLeft(2, '0')}:${(_timeLeft.inSeconds % 60).toString().padLeft(2, '0')}',
                        style: theme.textTheme.displaySmall?.copyWith(
                          fontWeight: FontWeight.w200,
                          letterSpacing: -1,
                          height: 1.0,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isRunning ? 'REMAINING' : 'READY',
                        style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.45),
                          letterSpacing: 3,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (_isRunning && _exitTime != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          '→ ${_formatTime(_exitTime!)}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: cs.onSurface.withValues(alpha: 0.4),
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 36),

            // ── Session Settings ─────────────────────────────────────────
            _sectionHeader(context, Icons.timer_outlined, 'SESSION SETTINGS'),
            const SizedBox(height: 16),

            _tappableRow(
              context,
              label: 'Check-in',
              value: _checkInTime.format(context),
              enabled: !_isRunning,
              onTap: () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: _checkInTime,
                );
                if (picked != null) setState(() => _checkInTime = picked);
              },
            ),
            _divider(context),

            _editableRow(
              context,
              label: 'Hours',
              controller: _hoursController,
              suffix: 'h',
              enabled: !_isRunning,
            ),
            _divider(context),

            _editableRow(
              context,
              label: 'Minutes',
              controller: _minutesController,
              suffix: 'min',
              enabled: !_isRunning,
            ),
            _divider(context),

            _editableRow(
              context,
              label: 'Notify before',
              controller: _notifyBeforeController,
              suffix: 'min',
              enabled: !_isRunning,
            ),

            const SizedBox(height: 36),

            // ── Geofencing ───────────────────────────────────────────────
            _sectionHeader(context, Icons.location_on_outlined, 'GEOFENCING'),
            const SizedBox(height: 16),

            _editableRow(
              context,
              label: 'Perimeter',
              controller: _perimeterController,
              suffix: 'm',
              enabled: !_isRunning,
              onChanged: (_) => _updatePerimeter(),
            ),
            _divider(context),

            _tappableRow(
              context,
              label: 'Location',
              value: _geofenceLocation != null ? 'Set' : 'Not set',
              onTap: _setCurrentLocationAsGeofence,
              trailing: _geofenceLocation != null
                  ? Icon(
                      Icons.check_circle_outline,
                      size: 16,
                      color: cs.onSurface.withValues(alpha: 0.5),
                    )
                  : null,
            ),

            if (_geofenceLocation != null) ...[
              _divider(context),
              _switchRow(
                context,
                label: 'Active',
                value: _geofenceEnabled,
                onChanged: (_) => _toggleGeofence(),
              ),
            ],

            const SizedBox(height: 36),

            // ── CTA ──────────────────────────────────────────────────────
            ElevatedButton(
              onPressed: _startTracking,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isRunning ? cs.error : cs.primary,
                foregroundColor: _isRunning ? cs.onError : cs.onPrimary,
                minimumSize: const Size(double.infinity, 56),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: Text(
                _isRunning ? 'STOP SESSION' : 'START SESSION',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  letterSpacing: 1.0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── UI Helpers ───────────────────────────────────────────────────────────

  Widget _sectionHeader(BuildContext context, IconData icon, String label) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Row(
      children: [
        Icon(icon, size: 14, color: cs.primary),
        const SizedBox(width: 8),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: cs.primary,
            letterSpacing: 2.0,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  Widget _divider(BuildContext context) {
    return Divider(
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
      thickness: 1,
      height: 1,
    );
  }

  Widget _tappableRow(
    BuildContext context, {
    required String label,
    required String value,
    VoidCallback? onTap,
    bool enabled = true,
    Widget? trailing,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.45,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.45),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      value,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
              trailing ??
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: cs.onSurface.withValues(alpha: 0.25),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _editableRow(
    BuildContext context, {
    required String label,
    required TextEditingController controller,
    required String suffix,
    bool enabled = true,
    Function(String)? onChanged,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.45),
              ),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: controller,
              enabled: enabled,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: onChanged,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.85),
              ),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                hintText: '0',
                hintStyle: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.25),
                ),
                suffix: Text(
                  suffix,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _switchRow(
    BuildContext context, {
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.85),
              ),
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: cs.primary,
            activeThumbColor: cs.onPrimary,
            inactiveTrackColor: cs.onSurface.withValues(alpha: 0.15),
          ),
        ],
      ),
    );
  }

  void _showPreferencesSheet(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(32, 28, 32, 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.tune_outlined, size: 14, color: cs.primary),
                const SizedBox(width: 8),
                Text(
                  'PREFERENCES',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.primary,
                    letterSpacing: 2.0,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Compact layout',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                  Switch(
                    value: widget.compactLayout,
                    onChanged: widget.onLayoutChanged,
                    activeTrackColor: cs.primary,
                    activeThumbColor: cs.onPrimary,
                    inactiveTrackColor: cs.onSurface.withValues(alpha: 0.15),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
