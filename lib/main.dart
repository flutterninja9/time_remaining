import 'dart:async';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:workmanager/workmanager.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      // Only process geofence check task
      if (task != 'geofenceCheck') {
        return Future.value(true);
      }

      // Check geofence status in background
      final prefs = await SharedPreferences.getInstance();
      final geofenceEnabled = prefs.getBool('geofence_enabled') ?? false;
      final lat = prefs.getDouble('geofence_latitude');
      final lon = prefs.getDouble('geofence_longitude');
      final radius = prefs.getDouble('geofence_radius') ?? 250.0;
      final isSessionRunning = prefs.getBool('is_running') ?? false;
      final lastNotificationTime = prefs.getInt(
        'last_geofence_notification_time',
      );

      // Prevent duplicate notifications within 5 minutes
      final now = DateTime.now().millisecondsSinceEpoch;
      if (lastNotificationTime != null) {
        final timeSinceLastNotification = now - lastNotificationTime;
        if (timeSinceLastNotification < 5 * 60 * 1000) {
          // 5 minutes
          return Future.value(true);
        }
      }

      if (!geofenceEnabled || lat == null || lon == null || isSessionRunning) {
        return Future.value(true);
      }

      // Check location permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        return Future.value(true);
      }

      // Get current position
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      );

      // Calculate distance
      final distance = Geolocator.distanceBetween(
        lat,
        lon,
        position.latitude,
        position.longitude,
      );

      // Check if inside geofence
      if (distance <= radius) {
        // Send notification
        final FlutterLocalNotificationsPlugin notificationsPlugin =
            FlutterLocalNotificationsPlugin();

        const androidSettings = AndroidInitializationSettings(
          '@mipmap/ic_launcher',
        );
        const iosSettings = DarwinInitializationSettings();
        await notificationsPlugin.initialize(
          const InitializationSettings(
            android: androidSettings,
            iOS: iosSettings,
          ),
        );

        const notificationDetails = NotificationDetails(
          android: AndroidNotificationDetails(
            'geofence_channel',
            'Geofence Alerts',
            importance: Importance.max,
            priority: Priority.high,
            color: Color(0xFF00E5FF),
          ),
        );

        await notificationsPlugin.show(
          2,
          'Time to Punch In!',
          'You\'ve arrived at your location. Tap to open the app and start your session.',
          notificationDetails,
        );

        // Save notification time to prevent duplicates
        await prefs.setInt('last_geofence_notification_time', now);
      }

      return Future.value(true);
    } catch (e) {
      debugPrint('Background geofence check error: $e');
      return Future.value(true);
    }
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Timezones for notifications
  tz.initializeTimeZones();

  // Initialize WorkManager for background location checks
  await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);

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

  // Geofencing variables
  Position? _geofenceLocation;
  double _geofenceRadius = 250.0; // Default 250 meters
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

  // --- Geofencing Logic ---
  Future<void> _initGeofencing() async {
    if (_geofenceEnabled && _geofenceLocation != null) {
      await _startLocationMonitoring();
    }
  }

  Future<bool> _requestLocationPermissions() async {
    // Check if location services are enabled
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Location services are disabled. Please enable them.',
            ),
          ),
        );
      }
      return false;
    }

    // Request permissions
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permissions are denied.')),
          );
        }
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Location permissions are permanently denied. Please enable them in settings.',
            ),
          ),
        );
      }
      return false;
    }

    // Request background location permission for Android
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
          const SnackBar(
            content: Text('Location set! Geofencing is now active.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint('Error getting location: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error getting location: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _startLocationMonitoring() async {
    if (!_geofenceEnabled || _geofenceLocation == null) return;

    final hasPermission = await _requestLocationPermissions();
    if (!hasPermission) {
      setState(() {
        _geofenceEnabled = false;
      });
      await _saveData();
      return;
    }

    // Stop existing monitoring if any
    await _stopLocationMonitoring();

    // Configure location settings for background monitoring
    LocationSettings locationSettings;
    if (Platform.isAndroid) {
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10, // Update every 10 meters
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

    // Start location stream (works in foreground and background)
    _positionStreamSubscription =
        Geolocator.getPositionStream(locationSettings: locationSettings).listen(
          (Position position) {
            _checkGeofenceStatus(position);
          },
          onError: (error) {
            debugPrint('Location stream error: $error');
          },
        );

    // Also register periodic background task for when app is closed
    // This runs every 15 minutes to check geofence status
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

    // Cancel background task
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

    // Only trigger notification when entering geofence (not already inside)
    if (isInside && !_isInsideGeofence) {
      _isInsideGeofence = true;

      // Check if session is not running before sending notification
      final prefs = await SharedPreferences.getInstance();
      final isSessionRunning = prefs.getBool('is_running') ?? false;

      // Prevent duplicate notifications within 5 minutes
      final now = DateTime.now().millisecondsSinceEpoch;
      final lastNotificationTime = prefs.getInt(
        'last_geofence_notification_time',
      );
      final shouldNotify =
          lastNotificationTime == null ||
          (now - lastNotificationTime) >= 5 * 60 * 1000; // 5 minutes

      if (!isSessionRunning && shouldNotify) {
        await _sendGeofenceNotification();
        await prefs.setInt('last_geofence_notification_time', now);
      }
    } else if (!isInside && _isInsideGeofence) {
      _isInsideGeofence = false;
    }
  }

  Future<void> _sendGeofenceNotification() async {
    const notificationDetails = NotificationDetails(
      android: AndroidNotificationDetails(
        'geofence_channel',
        'Geofence Alerts',
        importance: Importance.max,
        priority: Priority.high,
        color: Color(0xFF00E5FF),
      ),
    );

    await _notificationsPlugin.show(
      2, // Different ID for geofence notifications
      'Time to Punch In!',
      'You\'ve arrived at your location. Tap to open the app and start your session.',
      notificationDetails,
    );
  }

  Future<void> _updatePerimeter() async {
    final perimeter = double.tryParse(_perimeterController.text);
    if (perimeter != null && perimeter > 0) {
      setState(() {
        _geofenceRadius = perimeter;
      });
      await _saveData();

      if (_geofenceEnabled && _geofenceLocation != null) {
        await _startLocationMonitoring();
      }
    }
  }

  Future<void> _toggleGeofence() async {
    if (_geofenceLocation == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please set a location first.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    setState(() {
      _geofenceEnabled = !_geofenceEnabled;
    });

    await _saveData();

    if (_geofenceEnabled) {
      await _startLocationMonitoring();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Geofencing enabled.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } else {
      await _stopLocationMonitoring();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Geofencing disabled.')));
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

      // Load geofence settings
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

    // Save geofence settings
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
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 30),
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
              const SizedBox(height: 40),
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

              const SizedBox(height: 20),

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

              const SizedBox(height: 20),

              // Geofencing Settings Row
              Row(
                children: [
                  _buildInputCard(
                    "PERIMETER",
                    "${_perimeterController.text.isEmpty ? '250' : _perimeterController.text} m",
                    icon: Icons.location_on,
                    isTextField: true,
                    textController: _perimeterController,
                    hintText: "250",
                    isNumericOnly: true,
                    onChanged: (_) => _updatePerimeter(),
                  ),
                  const SizedBox(width: 20),
                  _buildInputCard(
                    "LOCATION",
                    _geofenceLocation != null ? "Set" : "Not Set",
                    icon: Icons.my_location,
                    onTap: _setCurrentLocationAsGeofence,
                    showStatus: _geofenceEnabled,
                  ),
                ],
              ),

              const SizedBox(height: 20),

              // Geofencing Toggle Button
              if (_geofenceLocation != null)
                ElevatedButton(
                  onPressed: _toggleGeofence,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _geofenceEnabled
                        ? Colors.green.withOpacity(0.8)
                        : Colors.grey.withOpacity(0.3),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _geofenceEnabled
                            ? Icons.location_on
                            : Icons.location_off,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _geofenceEnabled
                            ? "GEOFENCING ENABLED"
                            : "ENABLE GEOFENCING",
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
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
    Function(String)? onChanged,
    bool showStatus = false,
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
              border: Border.all(
                color: showStatus ? Colors.green : Colors.white10,
                width: showStatus ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Icon(icon, size: 20, color: Colors.cyanAccent),
                    if (showStatus)
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
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
                        onChanged: onChanged,
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
    _locationCheckTimer?.cancel();
    _positionStreamSubscription?.cancel();
    _hoursController.dispose();
    _minutesController.dispose();
    _notifyBeforeController.dispose();
    _perimeterController.dispose();
    super.dispose();
  }
}
