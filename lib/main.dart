import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:workmanager/workmanager.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'notification_service.dart';
import 'background_service.dart';
import 'webview_screen.dart';

// ── WorkManager callback dispatcher ────────────────────────────
// MUST be a top-level function (not inside a class)
// This runs in a separate Dart isolate when WorkManager fires a task
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    await BackgroundService.executeTask(taskName, inputData ?? {});
    return Future.value(true);
  });
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

  // Initialize WorkManager
  await Workmanager().initialize(
    callbackDispatcher,
    isInDebugMode: false,
  );

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
