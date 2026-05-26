import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';
import 'background_service.dart';
import 'webview_screen.dart';

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
