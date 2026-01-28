import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 10,
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationText: 'Monitoring location for geofencing',
            notificationTitle: 'Time Remaining',
            enableWakeLock: true,
          ),
        ),
        desiredAccuracy: LocationAccuracy.best,
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

