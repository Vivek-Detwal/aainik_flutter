import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

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
  static const String appData = 'aainik_app_data_v1';
}

/// ─────────────────────────────────────────────────────────────
/// BackgroundService
/// Handles inbox operations for Ego & Josh responses.
/// ─────────────────────────────────────────────────────────────
class BackgroundService {

  // ── Inbox Operations ───────────────────────────────────────────
  static const String _egoInboxKey  = 'aainik_ego_inbox_v1';
  static const String _joshInboxKey = 'aainik_josh_inbox_v1';

  /// Get the saved schedule string
  static Future<String?> getSchedule() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(PrefKeys.appData);
  }

  /// Get all inbox items for ego or josh
  static Future<List<Map<String, dynamic>>> getInboxItems(bool isEgo) async {
    final prefs = await SharedPreferences.getInstance();
    final key   = isEgo ? _egoInboxKey : _joshInboxKey;
    final json  = prefs.getString(key);
    if (json == null) return [];
    try {
      return (jsonDecode(json) as List<dynamic>).cast<Map<String, dynamic>>();
    } catch (_) { return []; }
  }

  /// Update an inbox item's response field (after in-app generation)
  static Future<void> updateInboxItemResponse({
    required bool isEgo,
    required String itemId,
    required String response,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key   = isEgo ? _egoInboxKey : _joshInboxKey;
    final json  = prefs.getString(key);
    if (json == null) return;
    try {
      final list = (jsonDecode(json) as List<dynamic>).cast<Map<String, dynamic>>();
      for (final item in list) {
        if (item['id'] == itemId) {
          item['response']       = response;
          item['responseReadAt'] = DateTime.now().millisecondsSinceEpoch;
          break;
        }
      }
      await prefs.setString(key, jsonEncode(list));
    } catch (_) {}
  }

  /// Clear all inbox items (optional utility)
  static Future<void> clearInbox(bool isEgo) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(isEgo ? _egoInboxKey : _joshInboxKey);
  }

  /// Get the raw app data (used by JS to build Gemini prompt for inbox responses)
  static Future<Map<String, dynamic>?> getAppDataForTime(String triggerTime) async {
    final prefs    = await SharedPreferences.getInstance();
    final dataJson = prefs.getString(PrefKeys.appData);
    if (dataJson == null) return null;
    try { return jsonDecode(dataJson) as Map<String, dynamic>; } catch (_) { return null; }
  }
}
