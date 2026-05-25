import 'dart:convert';
import 'dart:math';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';

// Forward reference — alarmCallback is defined in main.dart
// This import is NOT needed because alarmCallback is a top-level function
// registered by name via @pragma('vm:entry-point')
// The AndroidAlarmManager.oneShotAt call references it directly.

// Import the top-level alarmCallback so we can pass it to oneShotAt
// (Flutter requires the callback to be in scope at the call site)
import 'package:aainik_app/main.dart' show alarmCallback;

/// Alarm ID ranges — deterministic from the scheduled time.
/// Ego alarms:  10000 + (hour * 60 + minute)  → range 10000–11439
/// Josh alarms: 20000 + (hour * 60 + minute)  → range 20000–21439
class AlarmIds {
  static const int egoBase  = 10000;
  static const int joshBase = 20000;

  /// Returns alarm ID for an Ego task at given "HH:MM" time.
  static int forEgo(String time) {
    final parts = time.split(':');
    if (parts.length != 2) return egoBase;
    return egoBase + (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
  }

  /// Returns alarm ID for a Josh task at given "HH:MM" time.
  static int forJosh(String time) {
    final parts = time.split(':');
    if (parts.length != 2) return joshBase;
    return joshBase + (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
  }

  /// Reconstructs "HH:MM" trigger time string from alarm ID.
  static String triggerTimeFromId(int id) {
    final minutes = id >= joshBase ? id - joshBase : id - egoBase;
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  /// Returns true if this alarm ID belongs to Josh (not Ego).
  static bool isJosh(int id) => id >= joshBase;
}

/// Keys for SharedPreferences
class PrefKeys {
  static const String appData                 = 'aainik_app_data_v1';
  static const String pendingEgoConversations = 'aainik_pending_ego_convs';
  static const String pendingJoshConversations= 'aainik_pending_josh_convs';
  static const String scheduledAlarms         = 'aainik_scheduled_alarms_v2'; // {"ego":["10:00"],"josh":["09:00"]}
  static const String lastAlarmCheck          = 'aainik_last_alarm_check_v1'; // milliseconds int
}

/// ─────────────────────────────────────────────────────────────
/// BackgroundService
/// Called by android_alarm_manager_plus when an alarm fires.
/// Runs in a separate Dart isolate — app can be completely dead.
/// ─────────────────────────────────────────────────────────────
class BackgroundService {

  /// Entry point called from alarmCallback(int id) in main.dart.
  /// Determines task type from alarm ID, then:
  ///   1. Immediately reschedules for tomorrow (self-perpetuating)
  ///   2. Tries Gemini API → rich notification
  ///   3. If Gemini fails → fallback local-data notification
  static Future<void> handleAlarm(int alarmId) async {
    final triggerTime = AlarmIds.triggerTimeFromId(alarmId);
    final isJosh      = AlarmIds.isJosh(alarmId);

    // ── Step 1: Self-reschedule FIRST (before doing any work).
    // This ensures the alarm is registered for tomorrow even if the
    // Gemini call crashes or times out.
    await _rescheduleForTomorrow(alarmId, triggerTime);

    // ── Step 2: Run the actual task with Gemini + fallback
    if (isJosh) {
      await _runJoshAutoReminder(triggerTime);
    } else {
      await _runEgoAutoCheck(triggerTime);
    }
  }

  /// Re-registers the same alarm for the same time tomorrow.
  /// Uses alarmClock: true — highest priority, cannot be deferred by Android.
  static Future<void> _rescheduleForTomorrow(int alarmId, String triggerTime) async {
    try {
      final parts  = triggerTime.split(':');
      final hour   = int.tryParse(parts[0]) ?? 0;
      final minute = int.tryParse(parts[1]) ?? 0;

      final now = DateTime.now();
      // Always schedule for tomorrow at the same time
      final nextFire = DateTime(now.year, now.month, now.day + 1, hour, minute, 0);

      await AndroidAlarmManager.oneShotAt(
        nextFire,
        alarmId,
        alarmCallback,           // top-level function in main.dart
        exact: true,
        wakeup: true,            // wakes device from Doze
        rescheduleOnReboot: true,// package re-registers after device restart
        alarmClock: true,        // highest priority — same as Android's clock app
      );

      print('[BackgroundService] Rescheduled alarm $alarmId for $nextFire');
    } catch (e) {
      print('[BackgroundService] Reschedule error: $e');
    }
  }

  // ── Ego Auto Check ─────────────────────────────────────────────
  static Future<void> _runEgoAutoCheck(String triggerTime, {String? overrideDate}) async {
    SharedPreferences? prefs;
    String personality = 'beast';
    List<Map<String, dynamic>> tasksDueByNow = [];
    int doneCount = 0, totalDue = 0, pendingCount = 0, untrackedCount = 0;

    try {
      prefs = await SharedPreferences.getInstance();
      final dataJson = prefs.getString(PrefKeys.appData);
      if (dataJson == null) return;

      final appData  = jsonDecode(dataJson) as Map<String, dynamic>;
      final settings = appData['settings'] as Map<String, dynamic>? ?? {};

      if (settings['autoCoachEnabled'] != true) return;

      final apiKey = _getAvailableApiKey(settings);
      personality  = settings['autoCoachPersonality'] as String? ?? 'beast';

      final today = overrideDate ?? _getTodayStr();
      tasksDueByNow = _getTasksDueByNow(appData, triggerTime, today);
      doneCount     = tasksDueByNow.where((t) => t['completed'] == true).length;
      totalDue      = tasksDueByNow.length;
      pendingCount  = tasksDueByNow.where((t) => t['isPending']  == true).length;
      untrackedCount= tasksDueByNow.where((t) => t['isUntracked']== true).length;

      // ── Try Gemini first ──────────────────────────────────────
      if (apiKey != null && apiKey.isNotEmpty) {
        final lifeGoals    = settings['egoLifeGoals']    as String? ?? '';
        final negativeWords= settings['egoNegativeWords']as String? ?? '';
        final model        = settings['geminiModel']     as String? ?? 'gemini-2.5-flash';
        final searchEnabled= settings['geminiSearchEnabled'] != false;

        final systemPrompt = _buildEgoSystemPrompt(personality, lifeGoals, negativeWords);
        final userContent  = _buildEgoUserContent(
          triggerTime, tasksDueByNow, doneCount, totalDue, pendingCount, untrackedCount, appData,
        );

        String? fullResponse;
        try {
          fullResponse = await _callGemini(
            apiKey, model, systemPrompt, userContent, 800, searchEnabled,
          ).timeout(const Duration(seconds: 25));
        } catch (_) {
          fullResponse = null;
        }

        if (fullResponse != null && fullResponse.isNotEmpty) {
          // ── Gemini succeeded — show full AI notification ──────
          final lines    = fullResponse.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
          final headline = lines.isNotEmpty
              ? lines[0].replaceAll(RegExp(r'[*_#]'), '').substring(0, min(90, lines[0].length))
              : 'Tera-Ego ka check — dekho!';
          final notifBody= lines.length > 1
              ? lines.sublist(1).join('\n').trim()
              : fullResponse.trim();

          final notifId = 8000000 + (DateTime.now().millisecondsSinceEpoch % 999999);
          await NotificationService.showEgoNotification(
            id: notifId, title: '🧠 $headline', body: notifBody, fullText: fullResponse,
          );

          await _savePendingConversation(prefs, PrefKeys.pendingEgoConversations, {
            'id':          'conv_auto_bg_${DateTime.now().millisecondsSinceEpoch}',
            'type':        'auto',
            'triggerTime': triggerTime,
            'date':        today,
            'timestamp':   DateTime.now().millisecondsSinceEpoch,
            'scoreLabel':  '$doneCount/$totalDue done | Untracked: $untrackedCount | Pending: $pendingCount',
            'response':    fullResponse,
            'headline':    headline,
            'personality': personality,
            'source':      'background',
          });
          return; // Done — Gemini succeeded
        }
      }

      // ── Gemini failed / no key — show local-data fallback ────
      await _showEgoFallbackNotification(
        triggerTime: triggerTime,
        tasksDueByNow: tasksDueByNow,
        doneCount: doneCount,
        totalDue: totalDue,
        untrackedCount: untrackedCount,
        pendingCount: pendingCount,
        personality: personality,
      );

      // Save a lightweight pending entry so app shows the retry prompt
      if (prefs != null) {
        final today = overrideDate ?? _getTodayStr();
        await _savePendingConversation(prefs, PrefKeys.pendingEgoConversations, {
          'id':          'conv_auto_bg_fallback_${DateTime.now().millisecondsSinceEpoch}',
          'type':        'auto_fallback',
          'triggerTime': triggerTime,
          'date':        today,
          'timestamp':   DateTime.now().millisecondsSinceEpoch,
          'scoreLabel':  '$doneCount/$totalDue done | Fallback sent',
          'response':    _buildEgoFallbackText(tasksDueByNow, doneCount, totalDue, untrackedCount, pendingCount, personality),
          'headline':    'App khol — Ego full report wahan mil jayegi!',
          'personality': personality,
          'source':      'background_fallback',
        });
      }

    } catch (e) {
      print('[BackgroundService] Ego error: $e');
      // Last resort — show minimal fallback if we have any data
      try {
        if (tasksDueByNow.isNotEmpty) {
          await _showEgoFallbackNotification(
            triggerTime: triggerTime,
            tasksDueByNow: tasksDueByNow,
            doneCount: doneCount,
            totalDue: totalDue,
            untrackedCount: untrackedCount,
            pendingCount: pendingCount,
            personality: personality,
          );
        } else {
          // No data at all — minimal ping
          final notifId = 8000000 + (DateTime.now().millisecondsSinceEpoch % 999999);
          await NotificationService.showEgoNotification(
            id: notifId,
            title: '🧠 Ego check — $triggerTime',
            body: 'App khol — aaj ka performance check karna hai!',
            fullText: 'App khol — aaj ka performance check karna hai!',
          );
        }
      } catch (_) {}
    }
  }

  // ── Josh Auto Reminder ─────────────────────────────────────────
  static Future<void> _runJoshAutoReminder(String triggerTime, {String? overrideDate}) async {
    SharedPreferences? prefs;
    String personality = 'energetic';
    List<Map<String, dynamic>> upcomingTasks = [];
    Map<String, dynamic> dailyScore = {'done': 0, 'total': 0, 'score': 0};

    try {
      prefs = await SharedPreferences.getInstance();
      final dataJson = prefs.getString(PrefKeys.appData);
      if (dataJson == null) return;

      final appData  = jsonDecode(dataJson) as Map<String, dynamic>;
      final settings = appData['settings'] as Map<String, dynamic>? ?? {};

      if (settings['joshAutoEnabled'] != true) return;

      final apiKey = _getAvailableApiKey(settings);
      personality  = settings['joshPersonality'] as String? ?? 'energetic';

      final today = overrideDate ?? _getTodayStr();
      upcomingTasks = _getUpcomingTasks(appData, triggerTime, today);
      dailyScore    = _getDailyScore(appData, today);

      // ── Try Gemini first ──────────────────────────────────────
      if (apiKey != null && apiKey.isNotEmpty) {
        final lifeGoals    = settings['egoLifeGoals']    as String? ?? '';
        final negativeWords= settings['egoNegativeWords']as String? ?? '';
        final model        = settings['geminiModel']     as String? ?? 'gemini-2.5-flash';
        final searchEnabled= settings['geminiSearchEnabled'] != false;
        final joshPrompt   = settings['joshPrompt']      as String? ?? '';

        final systemPrompt = _buildJoshSystemPrompt(personality, lifeGoals, negativeWords, joshPrompt);
        final userContent  = _buildJoshUserContent(
          triggerTime, upcomingTasks, upcomingTasks.length, dailyScore, lifeGoals, negativeWords,
        );

        String? fullResponse;
        try {
          fullResponse = await _callGemini(
            apiKey, model, systemPrompt, userContent, 600, searchEnabled,
          ).timeout(const Duration(seconds: 25));
        } catch (_) {
          fullResponse = null;
        }

        if (fullResponse != null && fullResponse.isNotEmpty) {
          // ── Gemini succeeded — show full AI notification ──────
          final lines    = fullResponse.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
          final headline = lines.isNotEmpty
              ? lines[0].replaceAll(RegExp(r'[*_#]'), '').substring(0, min(90, lines[0].length))
              : 'Aaj ke tasks yaad hain? 💪';
          final notifBody= lines.length > 1
              ? lines.sublist(1).join('\n').trim()
              : fullResponse.trim();

          final notifId = 9000000 + (DateTime.now().millisecondsSinceEpoch % 999999);
          await NotificationService.showJoshNotification(
            id: notifId, title: '💪 $headline', body: notifBody, fullText: fullResponse,
          );

          await _savePendingConversation(prefs, PrefKeys.pendingJoshConversations, {
            'id':          'jc_auto_bg_${DateTime.now().millisecondsSinceEpoch}',
            'type':        'auto_reminder',
            'triggerTime': triggerTime,
            'date':        today,
            'timestamp':   DateTime.now().millisecondsSinceEpoch,
            'scoreLabel':  '💪 Tera-Josh Auto — ${upcomingTasks.length} tasks | $triggerTime',
            'response':    fullResponse,
            'headline':    headline,
            'source':      'background',
          });
          return; // Done — Gemini succeeded
        }
      }

      // ── Gemini failed / no key — show local-data fallback ────
      await _showJoshFallbackNotification(
        triggerTime: triggerTime,
        upcomingTasks: upcomingTasks,
        dailyScore: dailyScore,
        personality: personality,
      );

      if (prefs != null) {
        final today = overrideDate ?? _getTodayStr();
        await _savePendingConversation(prefs, PrefKeys.pendingJoshConversations, {
          'id':          'jc_auto_bg_fallback_${DateTime.now().millisecondsSinceEpoch}',
          'type':        'auto_fallback',
          'triggerTime': triggerTime,
          'date':        today,
          'timestamp':   DateTime.now().millisecondsSinceEpoch,
          'scoreLabel':  '💪 Josh Fallback | ${upcomingTasks.length} tasks | $triggerTime',
          'response':    _buildJoshFallbackText(upcomingTasks, dailyScore, personality),
          'headline':    'App khol — Josh poori tayaari ke saath wait kar raha hai!',
          'source':      'background_fallback',
        });
      }

    } catch (e) {
      print('[BackgroundService] Josh error: $e');
      try {
        if (upcomingTasks.isNotEmpty) {
          await _showJoshFallbackNotification(
            triggerTime: triggerTime,
            upcomingTasks: upcomingTasks,
            dailyScore: dailyScore,
            personality: personality,
          );
        } else {
          final notifId = 9000000 + (DateTime.now().millisecondsSinceEpoch % 999999);
          await NotificationService.showJoshNotification(
            id: notifId,
            title: '💪 Josh ka $triggerTime Reminder',
            body: 'App khol — Josh aaj ke tasks ke saath tera wait kar raha hai!',
            fullText: 'App khol — Josh aaj ke tasks ke saath tera wait kar raha hai!',
          );
        }
      } catch (_) {}
    }
  }

  // ── EGO Fallback Notification ──────────────────────────────────
  // Fires when Gemini API fails. Uses SharedPreferences data only.
  // Personality-aware text — not just "app me aao", real data.
  static Future<void> _showEgoFallbackNotification({
    required String triggerTime,
    required List<Map<String, dynamic>> tasksDueByNow,
    required int doneCount,
    required int totalDue,
    required int untrackedCount,
    required int pendingCount,
    required String personality,
  }) async {
    final pct = totalDue > 0 ? ((doneCount / totalDue) * 100).round() : 0;
    final body = _buildEgoFallbackText(
      tasksDueByNow, doneCount, totalDue, untrackedCount, pendingCount, personality,
    );

    String title;
    if (personality == 'beast') {
      if (pct == 0 && totalDue > 0) {
        title = '🧠 0% done bhai?! ($doneCount/$totalDue) — Ego wait kar raha hai!';
      } else if (pct >= 80) {
        title = '🧠 $pct% — acha hai, par Ego full report dega app mein!';
      } else {
        title = '🧠 Sirf $pct%? ($doneCount/$totalDue done) — Ego ka data ready hai!';
      }
    } else if (personality == 'balanced') {
      title = '🧠 Reality Check $triggerTime — $doneCount/$totalDue tasks ($pct%)';
    } else {
      title = '🧠 Tu aacha kar raha hai — $doneCount/$totalDue done! App khol 💜';
    }

    final notifId = 8000000 + (DateTime.now().millisecondsSinceEpoch % 999999);
    await NotificationService.showEgoNotification(
      id: notifId,
      title: title,
      body: body,
      fullText: '$title\n\n$body',
    );
  }

  static String _buildEgoFallbackText(
    List<Map<String, dynamic>> tasksDueByNow,
    int doneCount, int totalDue,
    int untrackedCount, int pendingCount,
    String personality,
  ) {
    final bodyParts = <String>[];
    final pct = totalDue > 0 ? ((doneCount / totalDue) * 100).round() : 0;

    // Show untracked tasks (worst — window closed, not done)
    final untrackedTasks = tasksDueByNow.where((t) => t['isUntracked'] == true).toList();
    if (untrackedTasks.isNotEmpty) {
      final names = untrackedTasks
          .map((t) => t['name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .join(', ');
      bodyParts.add(personality == 'beast'
          ? '⚠️ Untracked (window gone): $names'
          : '⚠️ Window close ho gayi: $names');
    }

    // Show pending tasks (window still open)
    final pendingTasks = tasksDueByNow.where((t) => t['isPending'] == true).toList();
    if (pendingTasks.isNotEmpty) {
      final pendingStr = pendingTasks
          .map((t) => '${t['name']} (→${t['workingWindowEnd']})')
          .where((s) => s.isNotEmpty)
          .join(', ');
      bodyParts.add('⏳ Abhi bhi time hai: $pendingStr');
    }

    // Show done count
    bodyParts.add('✅ Done: $doneCount/$totalDue ($pct%)');

    // Closing line — personality-matched
    if (personality == 'beast') {
      bodyParts.add('\nApp khol — Ego full roast de raha hai wahan, koi bahaana nahi!');
    } else if (personality == 'balanced') {
      bodyParts.add('\nApp khol — Ego full analysis aur next steps ready hain!');
    } else {
      bodyParts.add('\nApp khol — Ego tujhe encourage karna chahta hai, poori baat wahan! 💜');
    }

    return bodyParts.join('\n');
  }

  // ── JOSH Fallback Notification ─────────────────────────────────
  static Future<void> _showJoshFallbackNotification({
    required String triggerTime,
    required List<Map<String, dynamic>> upcomingTasks,
    required Map<String, dynamic> dailyScore,
    required String personality,
  }) async {
    final body = _buildJoshFallbackText(upcomingTasks, dailyScore, personality);

    String title;
    if (personality == 'beast') {
      title = '💪 CHAL UTH JA — $triggerTime | ${upcomingTasks.length} tasks abhi baki!';
    } else if (personality == 'calm') {
      title = '💪 Josh ka $triggerTime Reminder — ek ek kaam, aage badh';
    } else {
      title = '💪 Josh reminder — $triggerTime | Tu kar sakta hai! 🔥';
    }

    final notifId = 9000000 + (DateTime.now().millisecondsSinceEpoch % 999999);
    await NotificationService.showJoshNotification(
      id: notifId,
      title: title,
      body: body,
      fullText: '$title\n\n$body',
    );
  }

  static String _buildJoshFallbackText(
    List<Map<String, dynamic>> upcomingTasks,
    Map<String, dynamic> dailyScore,
    String personality,
  ) {
    final bodyParts = <String>[];
    final todayDone  = dailyScore['done']  as int? ?? 0;
    final todayTotal = dailyScore['total'] as int? ?? 0;

    // Show up to 5 upcoming tasks with their time slots
    final tasksToShow = upcomingTasks.take(5).toList();
    if (tasksToShow.isNotEmpty) {
      for (final task in tasksToShow) {
        final name     = task['name']            as String? ?? '';
        final start    = task['scheduledTime']   as String? ?? '';
        final end      = task['workingWindowEnd']as String? ?? '';
        final duration = task['duration']        as int?    ?? 0;
        if (name.isEmpty) continue;
        final timeStr  = (start.isNotEmpty && end.isNotEmpty) ? ' ($start→$end)' : '';
        final durStr   = duration > 0 ? ' — ${duration}min' : '';
        bodyParts.add('• $name$timeStr$durStr');
      }
      if (upcomingTasks.length > 5) {
        bodyParts.add('  ...aur ${upcomingTasks.length - 5} aur tasks');
      }
    } else {
      bodyParts.add('Koi upcoming tasks nahi — kal ka plan strong banao!');
    }

    // Today's current score
    if (todayTotal > 0) {
      bodyParts.add('\nAaj abhi tak: $todayDone/$todayTotal done');
    }

    // Closing line
    if (personality == 'beast') {
      bodyParts.add('App khol — Josh poori fire ke saath tera wait kar raha hai!');
    } else if (personality == 'calm') {
      bodyParts.add('App khol — Josh calm aur focused guidance de raha hai wahan!');
    } else {
      bodyParts.add('App khol — Josh ka full motivation wahan mil raha hai! 🚀');
    }

    return bodyParts.join('\n');
  }

  // ── Gemini API Call ────────────────────────────────────────────
  static Future<String?> _callGemini(
    String apiKey, String model, String systemPrompt,
    String userContent, int maxTokens, bool searchEnabled,
  ) async {
    final url = 'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey';

    final body = <String, dynamic>{
      'systemInstruction': {
        'parts': [{'text': systemPrompt}]
      },
      'contents': [
        {'role': 'user', 'parts': [{'text': userContent}]}
      ],
      'generationConfig': {
        'temperature': 0.85,
        'maxOutputTokens': maxTokens,
        'thinkingConfig': {'thinkingBudget': 0},
      },
    };

    if (searchEnabled) {
      body['tools'] = [{'google_search': {}}];
    }

    final response = await http.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 28));

    if (response.statusCode != 200) return null;

    final data       = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = data['candidates'] as List<dynamic>? ?? [];
    if (candidates.isEmpty) return null;

    final content = candidates[0]['content'] as Map<String, dynamic>? ?? {};
    final parts   = content['parts'] as List<dynamic>? ?? [];
    return parts
        .map((p) => (p as Map<String, dynamic>)['text'] as String? ?? '')
        .join('');
  }

  // ── Context builders ───────────────────────────────────────────

  static String _getTodayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  static String? _getAvailableApiKey(Map<String, dynamic> settings) {
    final key1 = settings['coachApiKey']  as String? ?? '';
    final key2 = settings['coachApiKey2'] as String? ?? '';
    final key3 = settings['coachApiKey3'] as String? ?? '';
    if (key1.isNotEmpty) return key1;
    if (key2.isNotEmpty) return key2;
    if (key3.isNotEmpty) return key3;
    return null;
  }

  static List<Map<String, dynamic>> _getTasksDueByNow(
    Map<String, dynamic> appData, String triggerTime, String today) {
    final tasks      = appData['tasks']      as List<dynamic>? ?? [];
    final history    = appData['history']    as List<dynamic>? ?? [];
    final categories = appData['categories'] as List<dynamic>? ?? [];

    return tasks
        .where((t) {
          final task = t as Map<String, dynamic>;
          if (task['active'] == false) return false;
          final startTime = task['workingWindowStart'] as String? ??
              task['scheduledTime'] as String? ?? '00:00';
          return startTime.compareTo(triggerTime) <= 0;
        })
        .map((t) {
          final task   = t as Map<String, dynamic>;
          final taskId = task['id'] as String;
          final entry  = history.cast<Map<String, dynamic>>().firstWhere(
            (h) => h['taskId'] == taskId && h['date'] == today,
            orElse: () => <String, dynamic>{},
          );
          final done         = entry['completed'] == true;
          final windowEnd    = task['workingWindowEnd'] as String? ?? '';
          final windowEndAfterNow = windowEnd.isNotEmpty && windowEnd.compareTo(triggerTime) > 0;

          final catId = task['categoryId'] as String? ?? '';
          final cat   = categories.cast<Map<String, dynamic>>().firstWhere(
            (c) => c['id'] == catId, orElse: () => {'name': ''});

          return <String, dynamic>{
            'name':             task['name'],
            'category':         cat['name'],
            'scheduledTime':    task['workingWindowStart'] ?? task['scheduledTime'],
            'workingWindowEnd': windowEnd,
            'whyMatters':       task['whyMatters'] ?? '',
            'completed':        done,
            'effortScore':      done ? (entry['effortScore'] ?? 0) : 0,
            'isUntracked':      !done && windowEnd.isNotEmpty && windowEnd.compareTo(triggerTime) <= 0,
            'isPending':        !done && windowEndAfterNow,
          };
        })
        .toList();
  }

  static List<Map<String, dynamic>> _getUpcomingTasks(
    Map<String, dynamic> appData, String triggerTime, String today) {
    final tasks      = appData['tasks']      as List<dynamic>? ?? [];
    final history    = appData['history']    as List<dynamic>? ?? [];
    final categories = appData['categories'] as List<dynamic>? ?? [];

    return tasks
        .where((t) {
          final task = t as Map<String, dynamic>;
          if (task['active'] == false) return false;
          final startTime = task['workingWindowStart'] as String? ??
              task['scheduledTime'] as String? ?? '00:00';
          return startTime.compareTo(triggerTime) >= 0;
        })
        .map((t) {
          final task   = t as Map<String, dynamic>;
          final taskId = task['id'] as String;
          final entry  = history.cast<Map<String, dynamic>>().firstWhere(
            (h) => h['taskId'] == taskId && h['date'] == today,
            orElse: () => <String, dynamic>{},
          );
          final done  = entry['completed'] == true;
          final catId = task['categoryId'] as String? ?? '';
          final cat   = categories.cast<Map<String, dynamic>>().firstWhere(
            (c) => c['id'] == catId, orElse: () => {'name': ''});

          return <String, dynamic>{
            'name':             task['name'],
            'category':         cat['name'],
            'scheduledTime':    task['workingWindowStart'] ?? task['scheduledTime'],
            'workingWindowEnd': task['workingWindowEnd'] ?? '',
            'whyMatters':       task['whyMatters'] ?? '',
            'completed':        done,
            'duration':         task['duration'] ?? 0,
          };
        })
        .toList();
  }

  static Map<String, dynamic> _getDailyScore(Map<String, dynamic> appData, String today) {
    final tasks   = (appData['tasks'] as List<dynamic>? ?? [])
        .where((t) => (t as Map)['active'] != false).toList();
    final history = appData['history'] as List<dynamic>? ?? [];

    int done = 0;
    for (final task in tasks) {
      final taskId = (task as Map)['id'] as String;
      final entry  = history.cast<Map<String, dynamic>>().firstWhere(
        (h) => h['taskId'] == taskId && h['date'] == today,
        orElse: () => <String, dynamic>{},
      );
      if (entry['completed'] == true) done++;
    }

    final total = tasks.length;
    final pct   = total > 0 ? (done / total * 100).round() : 0;
    return {'done': done, 'total': total, 'score': pct};
  }

  static String _buildEgoSystemPrompt(
    String personality, String lifeGoals, String negativeWords) {
    String tone;
    switch (personality) {
      case 'beast':
        tone = 'Tu ek brutal, no-excuse Hinglish life coach hai. Harsh, sarcastic if needed. '
            'Short punchy sentences. Hinglish (Hindi+English mix). No sugarcoating. '
            'Incomplete tasks pe roast kar, completed pe briefly acknowledge kar.';
        break;
      case 'balanced':
        tone = 'Tu ek honest Hinglish coach hai. Direct but not cruel. '
            'Hindi aur English naturally mix karo. Balanced — appreciate effort, address failures.';
        break;
      default:
        tone = 'Tu ek encouraging Hinglish coach hai. Warm but real. '
            'Positive framing. Failures ko growth opportunity se connect kar.';
    }

    return '''$tone

USER KE LIFE GOALS (in unke apne words):
${lifeGoals.isNotEmpty ? lifeGoals : 'Not set by user yet'}

LOG NE JO NEGATIVE KAHA HAI USER KE BAARE MEIN:
${negativeWords.isNotEmpty ? negativeWords : 'Not set by user yet'}

SPECIAL INSTRUCTIONS:
- Task names aur categories se context infer karo
- Har task ke "whyMatters" ko naturally weave karo
- Life goals se har incomplete task ko directly connect karo
- Negative words ko "prove them wrong energy" mein convert karo
- UNTRACKED (window closed, not done) = worst case, harshly address karo
- PENDING (window still open) = remaining time ka pressure do
- Response format: Line 1 = punchy headline (notification title, max 90 chars), then blank line, then detailed analysis''';
  }

  static String _buildEgoUserContent(
    String triggerTime,
    List<Map<String, dynamic>> tasksDueByNow,
    int doneCount, int totalDue,
    int pendingCount, int untrackedCount,
    Map<String, dynamic> appData,
  ) {
    final taskLines = tasksDueByNow.map((t) {
      final status = t['completed'] == true
          ? '✅ DONE (effort ${t['effortScore']}/10)'
          : t['isUntracked'] == true
              ? '⚠️ UNTRACKED (window closed — worst case 0 score)'
              : t['isPending'] == true
                  ? '⏳ PENDING (window abhi open hai — ${t['workingWindowEnd']} tak time hai)'
                  : '❌ NOT DONE';
      return '• [${t['category']}] ${t['name']} — $status | '
          'Window: ${t['scheduledTime']}→${t['workingWindowEnd']} | '
          'Why: ${t['whyMatters']}';
    }).join('\n');

    return '''AUTO CHECK TIME: $triggerTime
Tasks due by $triggerTime:
$taskLines

Summary: $doneCount/$totalDue done | Untracked: $untrackedCount | Pending (window open): $pendingCount

Format response as:
Line 1: Punchy headline title (notification ke liye — max 90 chars, Hinglish, personal aur direct)
Blank line
Full detailed reality check (task-by-task analysis, life goals, negative words — sab kuch use kar)''';
  }

  static String _buildJoshSystemPrompt(
    String personality, String lifeGoals, String negativeWords, String customPrompt) {
    if (customPrompt.isNotEmpty) return customPrompt;

    switch (personality) {
      case 'beast':
        return '''Tu ek josh-filled, fire-breathing Hinglish motivator hai.
"CHAL UTH JA BHAI" energy. Raw, intense, real.

USER KE LIFE GOALS: ${lifeGoals.isNotEmpty ? lifeGoals : 'Not set'}
NEGATIVE LOG NE KAHA: ${negativeWords.isNotEmpty ? negativeWords : 'Not set'}

Upcoming tasks ko life goals se connect kar. Negative words ko "prove them wrong" energy mein convert kar.
Format: Line 1 = punchy motivational headline (max 90 chars), blank line, then detailed motivation covering each task.''';

      case 'calm':
        return '''Tu ek calm, wise Hinglish mentor hai. Gentle but purposeful.
"Ek ek step, ek ek din" energy.

USER KE LIFE GOALS: ${lifeGoals.isNotEmpty ? lifeGoals : 'Not set'}
NEGATIVE LOG NE KAHA: ${negativeWords.isNotEmpty ? negativeWords : 'Not set'}

Format: Line 1 = warm headline (max 90 chars), blank line, thoughtful task-by-task guidance.''';

      default:
        return '''Tu ek energetic, positive Hinglish motivator hai.
High energy, infectious enthusiasm. "Tu kar sakta hai!" vibes.

USER KE LIFE GOALS: ${lifeGoals.isNotEmpty ? lifeGoals : 'Not set'}
NEGATIVE LOG NE KAHA: ${negativeWords.isNotEmpty ? negativeWords : 'Not set'}

Format: Line 1 = exciting headline (max 90 chars), blank line, energetic task-by-task motivation.''';
    }
  }

  static String _buildJoshUserContent(
    String triggerTime,
    List<Map<String, dynamic>> upcomingTasks,
    int totalUpcoming,
    Map<String, dynamic> dailyScore,
    String lifeGoals,
    String negativeWords,
  ) {
    final taskLines = upcomingTasks.map((t) =>
      '• [${t['category']}] ${t['name']} — ${t['scheduledTime']}→${t['workingWindowEnd']} | Why: ${t['whyMatters']}'
    ).join('\n');

    return '''TERA-JOSH REMINDER — Time: $triggerTime

UPCOMING TASKS ($triggerTime ke baad):
${taskLines.isNotEmpty ? taskLines : 'Koi upcoming tasks nahi — great, kal ke liye plan karo!'}

TODAY'S SCORE SO FAR: ${dailyScore['score']}% (${dailyScore['done']}/${dailyScore['total']} tasks done)

LIFE GOALS:
${lifeGoals.isNotEmpty ? lifeGoals : 'Not set'}

NEGATIVE WORDS (reframe into prove-them-wrong energy):
${negativeWords.isNotEmpty ? negativeWords : 'Not set'}

Format:
Line 1: Punchy motivational headline (notification title — max 90 chars, Hinglish, personal)
Blank line
Detailed reminder + motivation (each upcoming task separately, connect to life goals)''';
  }

  // ── Save pending conversation ──────────────────────────────────
  static Future<void> _savePendingConversation(
    SharedPreferences prefs, String key, Map<String, dynamic> conv) async {
    final existing = prefs.getString(key);
    List<dynamic> list = [];
    if (existing != null) {
      try { list = jsonDecode(existing) as List<dynamic>; } catch (_) {}
    }
    list.insert(0, conv);
    if (list.length > 30) list = list.sublist(0, 30);
    await prefs.setString(key, jsonEncode(list));
  }

  /// Called by WebView when it wants pending conversations
  static Future<Map<String, dynamic>> getPendingConversations() async {
    final prefs = await SharedPreferences.getInstance();
    List<dynamic> ego  = [];
    List<dynamic> josh = [];

    final egoJson  = prefs.getString(PrefKeys.pendingEgoConversations);
    if (egoJson  != null) { try { ego  = jsonDecode(egoJson)  as List<dynamic>; } catch (_) {} }

    final joshJson = prefs.getString(PrefKeys.pendingJoshConversations);
    if (joshJson != null) { try { josh = jsonDecode(joshJson) as List<dynamic>; } catch (_) {} }

    return {'egoConversations': ego, 'joshConversations': josh};
  }

  /// Clear pending conversations after WebView has consumed them
 /// Clear pending conversations after WebView has consumed them
  static Future<void> clearPendingConversations() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(PrefKeys.pendingEgoConversations);
    await prefs.remove(PrefKeys.pendingJoshConversations);
  }

  // ── Schedule Management ────────────────────────────────────────

  /// Save the currently scheduled ego/josh times so we can:
  ///  a) cancel only those IDs next time (no 2880-call loop)
  ///  b) detect which alarms missed when app opens
  static Future<void> saveSchedule(
      List<String> egoTimes, List<String> joshTimes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      PrefKeys.scheduledAlarms,
      jsonEncode({'ego': egoTimes, 'josh': joshTimes}),
    );
  }

  /// Returns the stored schedule as {ego: [...], josh: [...]}.
  static Future<Map<String, List<String>>> getSchedule() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(PrefKeys.scheduledAlarms);
    if (raw == null) return {'ego': [], 'josh': []};
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return {
        'ego':  (data['ego']  as List<dynamic>? ?? []).cast<String>(),
        'josh': (data['josh'] as List<dynamic>? ?? []).cast<String>(),
      };
    } catch (_) {
      return {'ego': [], 'josh': []};
    }
  }

  /// Stamp "now" as the last time the app was checked for missed alarms.
  static Future<void> updateLastAlarmCheck() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        PrefKeys.lastAlarmCheck, DateTime.now().millisecondsSinceEpoch);
  }

  /// Returns alarms that SHOULD have fired between the last check and now
  /// but were NOT already handled by the background service.
  /// These are the "missed" ones to process from the foreground queue.
  static Future<List<Map<String, dynamic>>> getMissedAlarms() async {
    final prefs = await SharedPreferences.getInstance();

    final raw = prefs.getString(PrefKeys.scheduledAlarms);
    if (raw == null) return [];
    Map<String, dynamic> schedule;
    try {
      schedule = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return [];
    }

    final egoTimes  = (schedule['ego']  as List<dynamic>? ?? []).cast<String>();
    final joshTimes = (schedule['josh'] as List<dynamic>? ?? []).cast<String>();
    if (egoTimes.isEmpty && joshTimes.isEmpty) return [];

    // Window: lastCheck → now (default: last 25h on first run)
    final lastCheckMs = prefs.getInt(PrefKeys.lastAlarmCheck);
    final lastCheck   = lastCheckMs != null
        ? DateTime.fromMillisecondsSinceEpoch(lastCheckMs)
        : DateTime.now().subtract(const Duration(hours: 25));
    final now = DateTime.now();

    // Build set of alarm slots already handled by background service
    final handled = <String>{};
    for (final key in [
      PrefKeys.pendingEgoConversations,
      PrefKeys.pendingJoshConversations,
    ]) {
      final isEgo = key == PrefKeys.pendingEgoConversations;
      final json  = prefs.getString(key);
      if (json == null) continue;
      try {
        final list = jsonDecode(json) as List<dynamic>;
        for (final c in list) {
          final m = c as Map<String, dynamic>;
          final d = m['date']        as String? ?? '';
          final t = m['triggerTime'] as String? ?? '';
          if (d.isNotEmpty && t.isNotEmpty) {
            handled.add('${isEgo ? 'ego' : 'josh'}_${d}_$t');
          }
        }
      } catch (_) {}
    }

    // Collect missed
    final missed = <Map<String, dynamic>>[];
    for (final time in egoTimes) {
      _collectMissed(time, 'ego', lastCheck, now, handled, missed);
    }
    for (final time in joshTimes) {
      _collectMissed(time, 'josh', lastCheck, now, handled, missed);
    }

    missed.sort((a, b) =>
        (a['alarmTime'] as int).compareTo(b['alarmTime'] as int));
    return missed;
  }

  static void _collectMissed(
    String time,
    String type,
    DateTime lastCheck,
    DateTime now,
    Set<String> handled,
    List<Map<String, dynamic>> missed,
  ) {
    final parts = time.split(':');
    if (parts.length != 2) return;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;

    // Check both yesterday and today (handles midnight crossings)
    for (int dayOffset = -1; dayOffset <= 0; dayOffset++) {
      final d    = now.add(Duration(days: dayOffset));
      final fire = DateTime(d.year, d.month, d.day, h, m);
      if (!fire.isAfter(lastCheck) || !fire.isBefore(now)) continue;

      final dateStr =
          '${fire.year}-${fire.month.toString().padLeft(2, '0')}-${fire.day.toString().padLeft(2, '0')}';
      final key = '${type}_${dateStr}_$time';
      if (handled.contains(key)) continue;

      missed.add({
        'type':      type,
        'time':      time,
        'date':      dateStr,
        'alarmTime': fire.millisecondsSinceEpoch,
      });
    }
  }

  /// Public entry point called from the foreground queue.
  /// Processes a single missed alarm (ego or josh) for a specific date.
  static Future<void> handleMissedAlarm({
    required String type,        // 'ego' or 'josh'
    required String triggerTime, // 'HH:MM'
    required String date,        // 'YYYY-MM-DD'
  }) async {
    if (type == 'ego') {
      await _runEgoAutoCheck(triggerTime, overrideDate: date);
    } else {
      await _runJoshAutoReminder(triggerTime, overrideDate: date);
    }
  }
}

