import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';
import 'background_service.dart';
import 'webview_screen.dart';

// ── AlarmManager callback dispatcher ────────────────────────────
// MUST be a top-level function (not inside a class).
// This runs in a separate Dart isolate when an alarm fires —
// even when the app is completely killed.
// The `id` parameter is the alarm ID we set in _scheduleAutoTask.
@pragma('vm:entry-point')
Future<void> alarmCallback(int id) async {
  // Required for Flutter plugin calls in a background isolate
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.initialize();
  await BackgroundService.handleAlarm(id);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Initialize local notifications
  await NotificationService.initialize();

  // Native AlarmManager is now handled via MethodChannel in MainActivity.kt
  // AndroidAlarmManager.initialize() no longer needed — all alarms are scheduled
  // and executed directly via BroadcastReceiver + Kotlin, ensuring 100% reliability
  // even on restrictive OEM devices (Xiaomi, Samsung, Oppo, etc.)
  // await AndroidAlarmManager.initialize();

  // Request battery optimization exemption — critical for background alarms on OEM phones
  try {
    final batteryStatus = await Permission.ignoreBatteryOptimizations.status;
    if (!batteryStatus.isGranted) {
      await Permission.ignoreBatteryOptimizations.request();
    }
  } catch (_) {}

  // On first ever launch: stamp now as last alarm check so missed-alarm
  // detector doesn't look back 25 hours before the user set anything up
  try {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(PrefKeys.lastAlarmCheck)) {
      await prefs.setInt(
          PrefKeys.lastAlarmCheck, DateTime.now().millisecondsSinceEpoch);
    }
  } catch (_) {}

  runApp(const AainikApp());
}

class AainikApp extends StatelessWidget {
  const AainikApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aainik',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFA29BFE),
          surface: Color(0xFF0f0f1a),
        ),
        scaffoldBackgroundColor: const Color(0xFF0f0f1a),
        useMaterial3: true,
      ),
      home: const WebViewScreen(),
    );
  }
}
