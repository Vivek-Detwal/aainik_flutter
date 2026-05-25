import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:workmanager/workmanager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'background_service.dart';

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
      navigationBarColor: Color(0xFF0f0f1a),
      navigationBarIconBrightness: Brightness.light,
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
                // Allow HTTP for local files but enforce HTTPS for API calls
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
    // Called every time saveData() runs in app.js
    // Stores full appData JSON in SharedPreferences for background tasks
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
    // Called when notification schedule changes
    // Registers/updates WorkManager tasks for Ego + Josh auto-mode
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
    // Called on app load to get any AI results from background tasks
    controller.addJavaScriptHandler(
      handlerName: 'requestPendingConversations',
      callback: (args) async {
        await _deliverPendingConversations();
      },
    );

    // ── JS Handler: clearPendingConversations ────────────────
    // Called after WebView has consumed pending conversations
    controller.addJavaScriptHandler(
      handlerName: 'clearPendingConversations',
      callback: (args) async {
        await BackgroundService.clearPendingConversations();
        debugPrint('[FlutterBridge] Pending conversations cleared');
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

    // Cancel all existing auto-mode tasks before rescheduling
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

  /// Schedule a OneTimeWorkRequest that fires at the given HH:MM time
  Future<void> _scheduleAutoTask({
    required String taskPrefix,
    required String time,
    required Map<String, dynamic> inputData,
  }) async {
    final now = DateTime.now();
    final parts = time.split(':');
    if (parts.length != 2) return;

    final hour = int.tryParse(parts[0]) ?? 0;
    final minute = int.tryParse(parts[1]) ?? 0;

    // Calculate next occurrence of this time
    var target = DateTime(now.year, now.month, now.day, hour, minute, 0);
    if (!target.isAfter(now.add(const Duration(minutes: 1)))) {
      // Already passed today — schedule for tomorrow
      target = target.add(const Duration(days: 1));
    }

    final delay = target.difference(now);
    final taskName = '$taskPrefix${time.replaceAll(':', '_')}';

    try {
      await Workmanager().registerOneOffTask(
        taskName,
        taskName,
        initialDelay: delay,
        constraints: Constraints(
          networkType: NetworkType.connected,
          requiresBatteryNotLow: false,
          requiresCharging: false,
          requiresDeviceIdle: false,
        ),
        existingWorkPolicy: ExistingWorkPolicy.replace,
        // inputData is limited to simple types — pass minimal needed info
        inputData: {
          'triggerTime': time,
          'taskType': taskPrefix.contains('ego') ? 'ego' : 'josh',
        },
      );
    } catch (e) {
      debugPrint('[FlutterBridge] scheduleAutoTask error: $e');
    }
  }

  Future<void> _cancelAllAutoTasks() async {
    try {
      await Workmanager().cancelByTag(TaskNames.egoAutoPrefix);
      await Workmanager().cancelByTag(TaskNames.joshAutoPrefix);
      // Also cancel by individual known names if any exist
    } catch (e) {
      debugPrint('[FlutterBridge] cancelAllAutoTasks error: $e');
    }
  }
}
