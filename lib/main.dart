import 'package:flutter/material.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:workmanager/workmanager.dart';

import 'app.dart';
import 'background/callback_dispatcher.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Timezones for notifications
  tz.initializeTimeZones();

  // Initialize WorkManager for background location checks
  await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);

  runApp(const TimeTrackerApp());
}
