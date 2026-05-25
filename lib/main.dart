import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
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

  // Initialize AlarmManager — replaces WorkManager
  await AndroidAlarmManager.initialize();

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
