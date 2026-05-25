import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';

/// WorkManager background task names
class TaskNames {
  static const String egoAutoPrefix = 'ego_auto_';
  static const String joshAutoPrefix = 'josh_auto_';
}

/// Keys for SharedPreferences
class PrefKeys {
  static const String appData = 'aainik_app_data_v1';
  static const String pendingEgoConversations = 'aainik_pending_ego_convs';
  static const String pendingJoshConversations = 'aainik_pending_josh_convs';
}

/// ─────────────────────────────────────────────────────────────
/// BackgroundService
/// Called by WorkManager when a background task fires.
/// Can run even when the app is completely killed.
/// ─────────────────────────────────────────────────────────────
class BackgroundService {
  static Future<void> executeTask(String taskName, Map<String, dynamic> inputData) async {
    // Initialize notification service for background context
    await NotificationService.initialize();

    if (taskName.startsWith(TaskNames.egoAutoPrefix)) {
      final triggerTime = taskName.substring(TaskNames.egoAutoPrefix.length);
      await _runEgoAutoCheck(triggerTime, inputData);
    } else if (taskName.startsWith(TaskNames.joshAutoPrefix)) {
      final triggerTime = taskName.substring(TaskNames.joshAutoPrefix.length);
      await _runJoshAutoReminder(triggerTime, inputData);
    }
  }

  // ── Ego Auto Check ────────────────────────────────────────────
  // Calls Gemini API with today's task progress context
  // Shows rich notification with full AI reality check
  static Future<void> _runEgoAutoCheck(String triggerTime, Map<String, dynamic> inputData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dataJson = prefs.getString(PrefKeys.appData);
      if (dataJson == null) return;

      final appData = jsonDecode(dataJson) as Map<String, dynamic>;
      final settings = appData['settings'] as Map<String, dynamic>? ?? {};

      if (settings['autoCoachEnabled'] != true) return;

      final apiKey = _getAvailableApiKey(settings);
      if (apiKey == null || apiKey.isEmpty) return;

      // Build context
      final today = _getTodayStr();
      final tasksDueByNow = _getTasksDueByNow(appData, triggerTime, today);
      final doneCount = tasksDueByNow.where((t) => t['completed'] == true).length;
      final totalDue = tasksDueByNow.length;
      final pendingCount = tasksDueByNow.where((t) => t['isPending'] == true).length;
      final untrackedCount = tasksDueByNow.where((t) => t['isUntracked'] == true).length;

      final personality = settings['autoCoachPersonality'] as String? ?? 'beast';
      final lifeGoals = settings['egoLifeGoals'] as String? ?? '';
      final negativeWords = settings['egoNegativeWords'] as String? ?? '';
      final model = settings['geminiModel'] as String? ?? 'gemini-2.5-flash';
      final searchEnabled = settings['geminiSearchEnabled'] != false;

      // Build prompts
      final systemPrompt = _buildEgoSystemPrompt(personality, lifeGoals, negativeWords);
      final userContent = _buildEgoUserContent(
        triggerTime, tasksDueByNow, doneCount, totalDue,
        pendingCount, untrackedCount, appData,
      );

      // Call Gemini API
      final fullResponse = await _callGemini(apiKey, model, systemPrompt, userContent, 800, searchEnabled);
      if (fullResponse == null) return;

      // Parse response
      final lines = fullResponse.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
      final headline = lines.isNotEmpty
          ? lines[0].replaceAll(RegExp(r'[*_#]'), '').substring(0, min(90, lines[0].length))
          : 'Tera-Ego ka check — dekho!';
      final notifBody = lines.length > 1
          ? lines.sublist(1).join('\n').trim()
          : fullResponse.trim();

      // Show notification
      final notifId = 8000000 + (DateTime.now().millisecondsSinceEpoch % 999999);
      await NotificationService.showEgoNotification(
        id: notifId,
        title: '🧠 $headline',
        body: notifBody,
        fullText: fullResponse,
      );

      // Save conversation to pending list so app can show it in history
      await _savePendingConversation(prefs, PrefKeys.pendingEgoConversations, {
        'id': 'conv_auto_bg_${DateTime.now().millisecondsSinceEpoch}',
        'type': 'auto',
        'triggerTime': triggerTime,
        'date': today,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'scoreLabel': '$doneCount/$totalDue done | Untracked: $untrackedCount | Pending: $pendingCount',
        'response': fullResponse,
        'headline': headline,
        'personality': personality,
        'source': 'background',
      });

    } catch (e) {
      // Silently fail — user shouldn't see crash dialogs from background tasks
      print('[BackgroundService] Ego error: $e');
    }
  }

  // ── Josh Auto Reminder ────────────────────────────────────────
  // Calls Gemini API with upcoming tasks context
  // Shows motivational notification
  static Future<void> _runJoshAutoReminder(String triggerTime, Map<String, dynamic> inputData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dataJson = prefs.getString(PrefKeys.appData);
      if (dataJson == null) return;

      final appData = jsonDecode(dataJson) as Map<String, dynamic>;
      final settings = appData['settings'] as Map<String, dynamic>? ?? {};

      if (settings['joshAutoEnabled'] != true) return;

      final apiKey = _getAvailableApiKey(settings);
      if (apiKey == null || apiKey.isEmpty) return;

      final today = _getTodayStr();
      final upcomingTasks = _getUpcomingTasks(appData, triggerTime, today);
      final totalUpcoming = upcomingTasks.length;

      final personality = settings['joshPersonality'] as String? ?? 'energetic';
      final lifeGoals = settings['egoLifeGoals'] as String? ?? '';
      final negativeWords = settings['egoNegativeWords'] as String? ?? '';
      final model = settings['geminiModel'] as String? ?? 'gemini-2.5-flash';
      final searchEnabled = settings['geminiSearchEnabled'] != false;
      final joshPrompt = settings['joshPrompt'] as String? ?? '';

      final dailyScore = _getDailyScore(appData, today);

      final systemPrompt = _buildJoshSystemPrompt(personality, lifeGoals, negativeWords, joshPrompt);
      final userContent = _buildJoshUserContent(
        triggerTime, upcomingTasks, totalUpcoming, dailyScore, lifeGoals, negativeWords,
      );

      final fullResponse = await _callGemini(apiKey, model, systemPrompt, userContent, 600, searchEnabled);
      if (fullResponse == null) return;

      final lines = fullResponse.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
      final headline = lines.isNotEmpty
          ? lines[0].replaceAll(RegExp(r'[*_#]'), '').substring(0, min(90, lines[0].length))
          : 'Aaj ke tasks yaad hain? 💪';
      final notifBody = lines.length > 1
          ? lines.sublist(1).join('\n').trim()
          : fullResponse.trim();

      final notifId = 9000000 + (DateTime.now().millisecondsSinceEpoch % 999999);
      await NotificationService.showJoshNotification(
        id: notifId,
        title: '💪 $headline',
        body: notifBody,
        fullText: fullResponse,
      );

      await _savePendingConversation(prefs, PrefKeys.pendingJoshConversations, {
        'id': 'jc_auto_bg_${DateTime.now().millisecondsSinceEpoch}',
        'type': 'auto_reminder',
        'triggerTime': triggerTime,
        'date': today,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'scoreLabel': '💪 Tera-Josh Auto — $totalUpcoming tasks | $triggerTime',
        'response': fullResponse,
        'headline': headline,
        'source': 'background',
      });

    } catch (e) {
      print('[BackgroundService] Josh error: $e');
    }
  }

  // ── Gemini API Call ───────────────────────────────────────────
  static Future<String?> _callGemini(
    String apiKey,
    String model,
    String systemPrompt,
    String userContent,
    int maxTokens,
    bool searchEnabled,
  ) async {
    try {
      final url = 'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey';

      final body = <String, dynamic>{
        'systemInstruction': {
          'parts': [{'text': systemPrompt}]
        },
        'contents': [
          {
            'role': 'user',
            'parts': [{'text': userContent}]
          }
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
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final candidates = data['candidates'] as List<dynamic>? ?? [];
      if (candidates.isEmpty) return null;

      final content = candidates[0]['content'] as Map<String, dynamic>? ?? {};
      final parts = content['parts'] as List<dynamic>? ?? [];
      return parts
          .map((p) => (p as Map<String, dynamic>)['text'] as String? ?? '')
          .join('');
    } catch (e) {
      print('[BackgroundService] Gemini error: $e');
      return null;
    }
  }

  // ── Context builders ──────────────────────────────────────────

  static String _getTodayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  static String? _getAvailableApiKey(Map<String, dynamic> settings) {
    final key1 = settings['coachApiKey'] as String? ?? '';
    final key2 = settings['coachApiKey2'] as String? ?? '';
    final key3 = settings['coachApiKey3'] as String? ?? '';
    if (key1.isNotEmpty) return key1;
    if (key2.isNotEmpty) return key2;
    if (key3.isNotEmpty) return key3;
    return null;
  }

  static List<Map<String, dynamic>> _getTasksDueByNow(
    Map<String, dynamic> appData, String triggerTime, String today) {
    final tasks = appData['tasks'] as List<dynamic>? ?? [];
    final history = appData['history'] as List<dynamic>? ?? [];
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
          final task = t as Map<String, dynamic>;
          final taskId = task['id'] as String;
          final entry = history.cast<Map<String, dynamic>>().firstWhere(
            (h) => h['taskId'] == taskId && h['date'] == today,
            orElse: () => <String, dynamic>{},
          );
          final done = entry['completed'] == true;
          final windowEnd = task['workingWindowEnd'] as String? ?? '';
          final windowEndAfterNow = windowEnd.isNotEmpty && windowEnd.compareTo(triggerTime) > 0;

          final catId = task['categoryId'] as String? ?? '';
          final cat = categories.cast<Map<String, dynamic>>().firstWhere(
            (c) => c['id'] == catId, orElse: () => {'name': ''});

          return <String, dynamic>{
            'name': task['name'],
            'category': cat['name'],
            'scheduledTime': task['workingWindowStart'] ?? task['scheduledTime'],
            'workingWindowEnd': windowEnd,
            'whyMatters': task['whyMatters'] ?? '',
            'completed': done,
            'effortScore': done ? (entry['effortScore'] ?? 0) : 0,
            'isUntracked': !done && windowEnd.isNotEmpty && windowEnd.compareTo(triggerTime) <= 0,
            'isPending': !done && windowEndAfterNow,
          };
        })
        .toList();
  }

  static List<Map<String, dynamic>> _getUpcomingTasks(
    Map<String, dynamic> appData, String triggerTime, String today) {
    final tasks = appData['tasks'] as List<dynamic>? ?? [];
    final history = appData['history'] as List<dynamic>? ?? [];
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
          final task = t as Map<String, dynamic>;
          final taskId = task['id'] as String;
          final entry = history.cast<Map<String, dynamic>>().firstWhere(
            (h) => h['taskId'] == taskId && h['date'] == today,
            orElse: () => <String, dynamic>{},
          );
          final done = entry['completed'] == true;

          final catId = task['categoryId'] as String? ?? '';
          final cat = categories.cast<Map<String, dynamic>>().firstWhere(
            (c) => c['id'] == catId, orElse: () => {'name': ''});

          return <String, dynamic>{
            'name': task['name'],
            'category': cat['name'],
            'scheduledTime': task['workingWindowStart'] ?? task['scheduledTime'],
            'workingWindowEnd': task['workingWindowEnd'] ?? '',
            'whyMatters': task['whyMatters'] ?? '',
            'completed': done,
            'duration': task['duration'] ?? 0,
          };
        })
        .toList();
  }

  static Map<String, dynamic> _getDailyScore(Map<String, dynamic> appData, String today) {
    final tasks = (appData['tasks'] as List<dynamic>? ?? [])
        .where((t) => (t as Map)['active'] != false)
        .toList();
    final history = appData['history'] as List<dynamic>? ?? [];

    int done = 0;
    for (final task in tasks) {
      final taskId = (task as Map)['id'] as String;
      final entry = history.cast<Map<String, dynamic>>().firstWhere(
        (h) => h['taskId'] == taskId && h['date'] == today,
        orElse: () => <String, dynamic>{},
      );
      if (entry['completed'] == true) done++;
    }

    final total = tasks.length;
    final pct = total > 0 ? (done / total * 100).round() : 0;
    return {'done': done, 'total': total, 'score': pct};
  }

  static String _buildEgoSystemPrompt(String personality, String lifeGoals, String negativeWords) {
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
      default: // gentle
        tone = 'Tu ek encouraging Hinglish coach hai. Warm but real. '
            'Positive framing. Failures ko growth opportunity se connect kar.';
    }

    return '''$tone

USER KE LIFE GOALS (in unke apne words):
${lifeGoals.isNotEmpty ? lifeGoals : 'Not set by user yet'}

LOG NE JO NEGATIVE KAHA HAI USER KE BAARE MEIN:
${negativeWords.isNotEmpty ? negativeWords : 'Not set by user yet'}

SPECIAL INSTRUCTIONS:
- Task names aur categories se context infer karo (e.g., PHYSIC > Morning Workout = body transformation)
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
    int doneCount,
    int totalDue,
    int pendingCount,
    int untrackedCount,
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

      default: // energetic
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

  // ── Save pending conversation ─────────────────────────────────
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
    List<dynamic> ego = [];
    List<dynamic> josh = [];

    final egoJson = prefs.getString(PrefKeys.pendingEgoConversations);
    if (egoJson != null) {
      try { ego = jsonDecode(egoJson) as List<dynamic>; } catch (_) {}
    }

    final joshJson = prefs.getString(PrefKeys.pendingJoshConversations);
    if (joshJson != null) {
      try { josh = jsonDecode(joshJson) as List<dynamic>; } catch (_) {}
    }

    return {'egoConversations': ego, 'joshConversations': josh};
  }

  /// Clear pending conversations after WebView has consumed them
  static Future<void> clearPendingConversations() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(PrefKeys.pendingEgoConversations);
    await prefs.remove(PrefKeys.pendingJoshConversations);
  }
}
