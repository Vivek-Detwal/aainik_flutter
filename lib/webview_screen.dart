import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:aainik_app/main.dart' show alarmCallback;
import 'package:shared_preferences/shared_preferences.dart';
import 'background_service.dart';
import 'notification_service.dart';

/// ─────────────────────────────────────────────────────────────
/// WebViewScreen
/// The main screen of the app — renders the existing web app
/// via InAppWebView and bridges JS ↔ Flutter communication.
/// ─────────────────────────────────────────────────────────────
class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> with WidgetsBindingObserver {
  InAppWebViewController? _webViewController;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Make status bar dark/transparent
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Color(0xFF0f0f1a),
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0f0f1a),
      systemNavigationBarIconBrightness: Brightness.light,
    ));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App came to foreground — deliver any pending AI conversations
      _deliverPendingConversations();
    }
  }

  Future<void> _deliverPendingConversations() async {
    try {
      final pending = await BackgroundService.getPendingConversations();
      final ego = pending['egoConversations'] as List<dynamic>? ?? [];
      final josh = pending['joshConversations'] as List<dynamic>? ?? [];

      if (ego.isEmpty && josh.isEmpty) return;

      final pendingJson = jsonEncode(pending);
      await _webViewController?.evaluateJavascript(
        source: 'if (typeof window._flutterInjectPendingConversations === "function") { '
            'window._flutterInjectPendingConversations(${jsonEncode(pendingJson)}); }',
      );
    } catch (e) {
      debugPrint('[WebViewScreen] deliverPendingConversations error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0f0f1a),
      body: SafeArea(
        child: Stack(
          children: [
            InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri('file:///android_asset/flutter_assets/assets/www/index.html'),
              ),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                allowFileAccessFromFileURLs: true,
                allowUniversalAccessFromFileURLs: true,
                mediaPlaybackRequiresUserGesture: false,
                javaScriptCanOpenWindowsAutomatically: true,
                supportZoom: false,
                builtInZoomControls: false,
                displayZoomControls: false,
                verticalScrollBarEnabled: false,
                horizontalScrollBarEnabled: false,
                transparentBackground: false,
                mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
                useWideViewPort: true,
                loadWithOverviewMode: true,
                userAgent: 'AainikApp/2.0 Flutter',
              ),
              onWebViewCreated: _onWebViewCreated,
              onLoadStart: (controller, url) {
                setState(() => _isLoading = true);
              },
              onLoadStop: (controller, url) {
                setState(() => _isLoading = false);
                // Deliver any pending conversations after page loads
                Future.delayed(const Duration(milliseconds: 2000), _deliverPendingConversations);
              },
              onPermissionRequest: (controller, request) async {
                return PermissionResponse(
                  resources: request.resources,
                  action: PermissionResponseAction.GRANT,
                );
              },
              onConsoleMessage: (controller, msg) {
                debugPrint('[WebView] ${msg.message}');
              },
            ),
            if (_isLoading)
              Container(
                color: const Color(0xFF0f0f1a),
                child: const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '⚡ AAINIK',
                        style: TextStyle(
                          color: Color(0xFFA29BFE),
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 4,
                        ),
                      ),
                      SizedBox(height: 16),
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: CircularProgressIndicator(
                          color: Color(0xFFA29BFE),
                          strokeWidth: 3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _onWebViewCreated(InAppWebViewController controller) {
    _webViewController = controller;

    // ── JS Handler: syncAppData ──────────────────────────────
    controller.addJavaScriptHandler(
      handlerName: 'syncAppData',
      callback: (args) async {
        try {
          final dataJson = args.isNotEmpty ? args[0] as String : null;
          if (dataJson == null || dataJson.isEmpty) return;

          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(PrefKeys.appData, dataJson);
          debugPrint('[FlutterBridge] appData synced (${dataJson.length} bytes)');
        } catch (e) {
          debugPrint('[FlutterBridge] syncAppData error: $e');
        }
      },
    );

    // ── JS Handler: scheduleBackgroundTasks ─────────────────
    controller.addJavaScriptHandler(
      handlerName: 'scheduleBackgroundTasks',
      callback: (args) async {
        try {
          final scheduleJson = args.isNotEmpty ? args[0] as String : null;
          if (scheduleJson == null || scheduleJson.isEmpty) return;

          final config = jsonDecode(scheduleJson) as Map<String, dynamic>;
          await _registerBackgroundTasks(config);
        } catch (e) {
          debugPrint('[FlutterBridge] scheduleBackgroundTasks error: $e');
        }
      },
    );

    // ── JS Handler: requestPendingConversations ──────────────
    controller.addJavaScriptHandler(
      handlerName: 'requestPendingConversations',
      callback: (args) async {
        await _deliverPendingConversations();
      },
    );

    // ── JS Handler: clearPendingConversations ────────────────
    controller.addJavaScriptHandler(
      handlerName: 'clearPendingConversations',
      callback: (args) async {
        await BackgroundService.clearPendingConversations();
        debugPrint('[FlutterBridge] Pending conversations cleared');
      },
    );

    // ── FIX: JS Handler: showNotification ───────────────────
    // Called by the window.Notification shim in flutter_bridge.js
    // whenever JS does `new Notification(title, {body: ...})`.
    // Routes the notification to Flutter's NotificationService
    // so it shows as a real Android system notification.
    controller.addJavaScriptHandler(
      handlerName: 'showNotification',
      callback: (args) async {
        try {
          final dataJson = args.isNotEmpty ? args[0] as String : null;
          if (dataJson == null || dataJson.isEmpty) return;

          final data = jsonDecode(dataJson) as Map<String, dynamic>;
          final title = (data['title'] as String?) ?? 'Aainik';
          final body = (data['body'] as String?) ?? '';

          // Use a time-based ID to avoid collisions between notifications
          final id = DateTime.now().millisecondsSinceEpoch % 99999;

          await NotificationService.showTaskNotification(
            id: id,
            title: title,
            body: body,
          );
          debugPrint('[FlutterBridge] showNotification: $title');
        } catch (e) {
          debugPrint('[FlutterBridge] showNotification error: $e');
        }
      },
    );

    // ── FIX: JS Handler: requestNotificationPermission ──────
    // Called by flutter_bridge.js shim when JS code calls
    // Notification.requestPermission(). Ensures Flutter has
    // actually been granted notification permission on Android 13+.
    controller.addJavaScriptHandler(
      handlerName: 'requestNotificationPermission',
      callback: (args) async {
        try {
          final androidPlugin = FlutterLocalNotificationsPlugin()
              .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin>();
          if (androidPlugin != null) {
            final granted = await androidPlugin.requestNotificationsPermission();
            debugPrint('[FlutterBridge] Notification permission: $granted');
          }
        } catch (e) {
          debugPrint('[FlutterBridge] requestNotificationPermission error: $e');
        }
      },
    );
  }

  // ── Register WorkManager Tasks ─────────────────────────────
  Future<void> _registerBackgroundTasks(Map<String, dynamic> config) async {
    final egoEnabled = config['egoEnabled'] == true;
    final joshEnabled = config['joshEnabled'] == true;

    final egoTimes = (config['egoTimes'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    final joshTimes = (config['joshTimes'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();

    await _cancelAllAutoTasks();

    if (egoEnabled) {
      for (final entry in egoTimes) {
        final time = entry['time'] as String?;
        if (time == null || time.isEmpty) continue;
        await _scheduleAutoTask(
          taskPrefix: TaskNames.egoAutoPrefix,
          time: time,
          inputData: config,
        );
        debugPrint('[FlutterBridge] Scheduled Ego task at $time');
      }
    }

    if (joshEnabled) {
      for (final entry in joshTimes) {
        final time = entry['time'] as String?;
        if (time == null || time.isEmpty) continue;
        await _scheduleAutoTask(
          taskPrefix: TaskNames.joshAutoPrefix,
          time: time,
          inputData: config,
        );
        debugPrint('[FlutterBridge] Scheduled Josh task at $time');
      }
    }
  }
Future<void> _scheduleAutoTask({
    required String taskPrefix,
    required String time,
    required Map<String, dynamic> inputData,
  }) async {
    final now   = DateTime.now();
    final parts = time.split(':');
    if (parts.length != 2) return;

    final hour   = int.tryParse(parts[0]) ?? 0;
    final minute = int.tryParse(parts[1]) ?? 0;

    // Target = today at scheduled time, or tomorrow if that's already passed
    var target = DateTime(now.year, now.month, now.day, hour, minute, 0);
    if (!target.isAfter(now.add(const Duration(minutes: 1)))) {
      target = target.add(const Duration(days: 1));
    }

    // Determine alarm ID from task type + time
    final isEgo  = taskPrefix.contains('ego');
    final alarmId= isEgo ? AlarmIds.forEgo(time) : AlarmIds.forJosh(time);

    try {
      await AndroidAlarmManager.oneShotAt(
        target,
        alarmId,
        alarmCallback,          // top-level callback in main.dart
        exact: true,            // no deferral
        wakeup: true,           // wake device from Doze
        rescheduleOnReboot: true, // re-register after phone restart
        alarmClock: true,       // highest Android priority, shown in status bar
      );
      debugPrint('[FlutterBridge] Alarm $alarmId set for ${isEgo ? 'Ego' : 'Josh'} at $target');
    } catch (e) {
      debugPrint('[FlutterBridge] scheduleAutoTask error: $e');
    }
  }
  Future<void> _cancelAllAutoTasks() async {
    // Cancel all possible ego and josh alarm IDs
    // Alarm ID range: ego 10000–11439, josh 20000–21439
    // We iterate all possible HH:MM combinations (1440 possibilities per type)
    // but only actually cancel ones that exist — Android ignores unknown IDs.
    try {
      for (int minutes = 0; minutes < 1440; minutes++) {
        await AndroidAlarmManager.cancel(AlarmIds.egoBase  + minutes);
        await AndroidAlarmManager.cancel(AlarmIds.joshBase + minutes);
      }
      debugPrint('[FlutterBridge] All alarms cancelled');
    } catch (e) {
      debugPrint('[FlutterBridge] cancelAllAutoTasks error: $e');
    }
  }
}
