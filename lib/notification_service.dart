import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const String _channelTasks = 'aainik-tasks';
  static const String _channelEgo = 'aainik-ego';
  static const String _channelJosh = 'aainik-josh';

  static Future<void> initialize() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTap,
    );

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelTasks,
          'Task Reminders',
          description: 'Daily task reminder notifications',
          importance: Importance.high,
          enableVibration: true,
          ledColor: Color(0xFFA29BFE),
          playSound: true,
        ),
      );

      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelEgo,
          'Ego AI Reports',
          description: 'Tera-Ego AI reality check notifications',
          importance: Importance.high,
          enableVibration: true,
          ledColor: Color(0xFFA29BFE),
          playSound: true,
        ),
      );

      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelJosh,
          'Josh Reminders',
          description: 'Tera-Josh motivational reminders',
          importance: Importance.high,
          enableVibration: true,
          ledColor: Color(0xFF55EFC4),
          playSound: true,
        ),
      );

      await androidPlugin.requestExactAlarmsPermission();
    }

    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  static void _onNotificationTap(NotificationResponse response) {}

  static Future<void> showEgoNotification({
    required int id,
    required String title,
    required String body,
    required String fullText,
  }) async {
    final style = BigTextStyleInformation(
      fullText.substring(0, fullText.length > 1200 ? 1200 : fullText.length),
      htmlFormatBigText: false,
      contentTitle: title,
      htmlFormatContentTitle: false,
      summaryText: 'Tap to open Tera-Ego',
      htmlFormatSummaryText: false,
    );

    final androidDetails = AndroidNotificationDetails(
      _channelEgo,
      'Ego AI Reports',
      channelDescription: 'Tera-Ego AI reality check notifications',
      importance: Importance.high,
      priority: Priority.high,
      styleInformation: style,
      ticker: title,
      icon: '@mipmap/ic_launcher',
      color: const Color(0xFFA29BFE),
      playSound: true,
      enableVibration: true,
    );

    await _plugin.show(
      id,
      title,
      body.length > 150 ? '${body.substring(0, 150)}...' : body,
      NotificationDetails(android: androidDetails),
      payload: 'coach:ego',
    );
  }

  static Future<void> showJoshNotification({
    required int id,
    required String title,
    required String body,
    required String fullText,
  }) async {
    final style = BigTextStyleInformation(
      fullText.substring(0, fullText.length > 1200 ? 1200 : fullText.length),
      htmlFormatBigText: false,
      contentTitle: title,
      htmlFormatContentTitle: false,
      summaryText: 'Tap to open Tera-Josh',
      htmlFormatSummaryText: false,
    );

    final androidDetails = AndroidNotificationDetails(
      _channelJosh,
      'Josh Reminders',
      channelDescription: 'Tera-Josh motivational reminders',
      importance: Importance.high,
      priority: Priority.high,
      styleInformation: style,
      ticker: title,
      icon: '@mipmap/ic_launcher',
      color: const Color(0xFF55EFC4),
      playSound: true,
      enableVibration: true,
    );

    await _plugin.show(
      id,
      title,
      body.length > 150 ? '${body.substring(0, 150)}...' : body,
      NotificationDetails(android: androidDetails),
      payload: 'coach:josh',
    );
  }

  static Future<void> showTaskNotification({
    required int id,
    required String title,
    required String body,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      _channelTasks,
      'Task Reminders',
      channelDescription: 'Daily task reminder notifications',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      color: Color(0xFFA29BFE),
      playSound: true,
      enableVibration: true,
    );

    await _plugin.show(
      id,
      title,
      body,
      const NotificationDetails(android: androidDetails),
    );
  }
}
