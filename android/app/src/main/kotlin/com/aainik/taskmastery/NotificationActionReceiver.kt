package com.aainik.taskmastery

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.util.Calendar

class NotificationActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_SEND_EGO_RESPONSE  = "com.aainik.taskmastery.SEND_EGO_RESPONSE"
        const val ACTION_SEND_JOSH_RESPONSE = "com.aainik.taskmastery.SEND_JOSH_RESPONSE"
        const val EXTRA_HOUR     = "hour"
        const val EXTRA_MINUTE   = "minute"
        const val EXTRA_ALARM_ID = "alarm_id"
        const val EXTRA_INBOX_ID = "inbox_id"
        const val CHANNEL_EGO    = "aainik-ego"
        const val CHANNEL_JOSH   = "aainik-josh"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != ACTION_SEND_EGO_RESPONSE && action != ACTION_SEND_JOSH_RESPONSE) return

        val isEgo   = action == ACTION_SEND_EGO_RESPONSE
        val hour    = intent.getIntExtra(EXTRA_HOUR, 0)
        val minute  = intent.getIntExtra(EXTRA_MINUTE, 0)
        val alarmId = intent.getIntExtra(EXTRA_ALARM_ID, 0)
        val inboxId = intent.getStringExtra(EXTRA_INBOX_ID) ?: ""
        val timeStr = String.format("%02d:%02d", hour, minute)

        // Show "Processing..." notification immediately (on main thread — fast)
        showProcessingNotification(context, isEgo, timeStr)

        // Do the heavy work (network calls) on a background thread
        Thread {
            try {
                val prefs    = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                val dataJson = prefs.getString("flutter.aainik_app_data_v1", null) ?: return@Thread
                val appData  = JSONObject(dataJson)
                val settings = appData.optJSONObject("settings") ?: JSONObject()

                // Get first available API key
                val apiKey = listOf("coachApiKey", "coachApiKey2", "coachApiKey3")
                    .map { settings.optString(it, "") }
                    .firstOrNull { it.isNotEmpty() } ?: return@Thread

                val model          = settings.optString("geminiModel", "gemini-2.5-flash")
                val searchEnabled  = settings.optBoolean("geminiSearchEnabled", true)
                val personality    = if (isEgo) settings.optString("autoCoachPersonality", "beast")
                                     else settings.optString("joshPersonality", "energetic")
                val lifeGoals      = settings.optString("egoLifeGoals", "")
                val negWords       = settings.optString("egoNegativeWords", "")
                val telegramToken  = settings.optString("telegramBotToken", "")
                val telegramChatId = settings.optString("telegramChatId", "")
                val today          = todayStr()

                val (systemPrompt, userContent) = if (isEgo) {
                    buildEgoPrompt(personality, lifeGoals, negWords, appData, timeStr, today)
                } else {
                    buildJoshPrompt(personality, lifeGoals, negWords, appData, timeStr, today)
                }

                val response = callGemini(apiKey, model, systemPrompt, userContent, 800, searchEnabled)

                if (response != null && response.isNotEmpty()) {
                    var sentToTelegram = false
                    if (telegramToken.isNotEmpty() && telegramChatId.isNotEmpty()) {
                        val label = if (isEgo) "🧠 Ego Response — $timeStr" else "💪 Josh Response — $timeStr"
                        sentToTelegram = sendToTelegram(telegramToken, telegramChatId, "$label\n\n$response")
                    }
                    updateInboxItem(prefs, isEgo, inboxId, response, sentToTelegram)
                    showSuccessNotification(context, isEgo, timeStr, sentToTelegram)
                } else {
                    showErrorNotification(context, isEgo, timeStr)
                }

            } catch (e: Exception) {
                showErrorNotification(context, isEgo, timeStr)
            }
        }.start()
    }

    // ── Prompt Builders ────────────────────────────────────────

    private fun buildEgoPrompt(
        personality: String, lifeGoals: String, negWords: String,
        appData: JSONObject, timeStr: String, today: String
    ): Pair<String, String> {
        val tone = when (personality) {
            "beast"    -> "Tu ek brutal, no-excuse Hinglish life coach hai. Harsh, sarcastic if needed. Short punchy sentences. No sugarcoating."
            "balanced" -> "Tu ek honest Hinglish coach hai. Direct but not cruel. Balanced — appreciate effort, address failures."
            else       -> "Tu ek encouraging Hinglish coach hai. Warm but real. Positive framing."
        }
        val systemPrompt = "$tone\nUSER KE LIFE GOALS: ${lifeGoals.ifEmpty { "Not set" }}\nLOG NE JO NEGATIVE KAHA: ${negWords.ifEmpty { "Not set" }}\nFormat: Line 1 = punchy headline (max 90 chars), blank line, then detailed analysis"

        val tasks   = appData.optJSONArray("tasks") ?: JSONArray()
        val history = appData.optJSONArray("history") ?: JSONArray()
        val sb      = StringBuilder()
        var done = 0; var total = 0

        for (i in 0 until tasks.length()) {
            val t = tasks.getJSONObject(i)
            if (!t.optBoolean("active", true)) continue
            val start = t.optString("workingWindowStart", t.optString("scheduledTime", "00:00"))
            if (start > timeStr) continue
            total++
            val taskId = t.optString("id", "")
            var taskDone = false
            for (j in 0 until history.length()) {
                val h = history.getJSONObject(j)
                if (h.optString("taskId") == taskId && h.optString("date") == today) {
                    taskDone = h.optBoolean("completed", false); break
                }
            }
            if (taskDone) done++
            val status = if (taskDone) "✅ DONE" else "❌ NOT DONE"
            sb.append("• ${t.optString("name")} — $status | Window: $start→${t.optString("workingWindowEnd")}\n")
        }
        val userContent = "AUTO CHECK TIME: $timeStr\nTasks due by $timeStr:\n$sb\nSummary: $done/$total done"
        return Pair(systemPrompt, userContent)
    }

    private fun buildJoshPrompt(
        personality: String, lifeGoals: String, negWords: String,
        appData: JSONObject, timeStr: String, today: String
    ): Pair<String, String> {
        val systemPrompt = when (personality) {
            "beast" -> "Tu ek josh-filled Hinglish motivator hai. CHAL UTH JA energy.\nUSER KE LIFE GOALS: ${lifeGoals.ifEmpty { "Not set" }}\nFormat: Line 1 = punchy headline, blank line, detailed motivation"
            "calm"  -> "Tu ek calm Hinglish mentor hai. Gentle but purposeful.\nUSER KE LIFE GOALS: ${lifeGoals.ifEmpty { "Not set" }}\nFormat: Line 1 = warm headline, blank line, thoughtful guidance"
            else    -> "Tu ek energetic Hinglish motivator hai.\nUSER KE LIFE GOALS: ${lifeGoals.ifEmpty { "Not set" }}\nFormat: Line 1 = exciting headline, blank line, energetic motivation"
        }
        val tasks   = appData.optJSONArray("tasks") ?: JSONArray()
        val history = appData.optJSONArray("history") ?: JSONArray()
        val sb      = StringBuilder()
        var done = 0; var total = 0

        for (i in 0 until tasks.length()) {
            val t = tasks.getJSONObject(i)
            if (!t.optBoolean("active", true)) continue
            total++
            val start  = t.optString("workingWindowStart", t.optString("scheduledTime", "00:00"))
            val taskId = t.optString("id", "")
            var taskDone = false
            for (j in 0 until history.length()) {
                val h = history.getJSONObject(j)
                if (h.optString("taskId") == taskId && h.optString("date") == today) {
                    taskDone = h.optBoolean("completed", false); break
                }
            }
            if (taskDone) done++
            if (start >= timeStr && !taskDone) sb.append("• ${t.optString("name")} ($start→${t.optString("workingWindowEnd")})\n")
        }
        val userContent = "JOSH REMINDER — $timeStr\nUpcoming tasks:\n$sb\nToday: $done/$total done"
        return Pair(systemPrompt, userContent)
    }

    // ── Network Calls ──────────────────────────────────────────

    private fun callGemini(
        apiKey: String, model: String, systemPrompt: String,
        userContent: String, maxTokens: Int, searchEnabled: Boolean
    ): String? {
        return try {
            val url  = URL("https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                setRequestProperty("Content-Type", "application/json")
                doOutput = true
                connectTimeout = 30000
                readTimeout    = 30000
            }
            val tools = if (searchEnabled) ""","tools":[{"google_search":{}}]""" else ""
            val body  = """{"systemInstruction":{"parts":[{"text":${JSONObject.quote(systemPrompt)}}]},"contents":[{"role":"user","parts":[{"text":${JSONObject.quote(userContent)}}]}],"generationConfig":{"temperature":0.85,"maxOutputTokens":$maxTokens,"thinkingConfig":{"thinkingBudget":0}}$tools}"""
            OutputStreamWriter(conn.outputStream).use { it.write(body) }
            if (conn.responseCode != 200) return null
            val resp = BufferedReader(InputStreamReader(conn.inputStream)).use { it.readText() }
            val json = JSONObject(resp)
            val candidates = json.optJSONArray("candidates") ?: return null
            if (candidates.length() == 0) return null
            val parts = candidates.getJSONObject(0).optJSONObject("content")?.optJSONArray("parts") ?: return null
            val out = StringBuilder()
            for (i in 0 until parts.length()) out.append(parts.getJSONObject(i).optString("text", ""))
            out.toString().trim()
        } catch (e: Exception) { null }
    }

    private fun sendToTelegram(token: String, chatId: String, text: String): Boolean {
        return try {
            val url  = URL("https://api.telegram.org/bot$token/sendMessage")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                setRequestProperty("Content-Type", "application/json")
                doOutput = true
                connectTimeout = 15000
                readTimeout    = 15000
            }
            val truncated = if (text.length > 4000) text.substring(0, 4000) + "..." else text
            val body = """{"chat_id":${JSONObject.quote(chatId)},"text":${JSONObject.quote(truncated)},"parse_mode":""}"""
            OutputStreamWriter(conn.outputStream).use { it.write(body) }
            conn.responseCode == 200
        } catch (e: Exception) { false }
    }

    // ── SharedPreferences ──────────────────────────────────────

    private fun updateInboxItem(
        prefs: android.content.SharedPreferences, isEgo: Boolean,
        inboxId: String, response: String, sentToTelegram: Boolean
    ) {
        try {
            val key      = if (isEgo) "flutter.aainik_ego_inbox_v1" else "flutter.aainik_josh_inbox_v1"
            val existing = prefs.getString(key, "[]") ?: "[]"
            val arr      = JSONArray(existing)
            for (i in 0 until arr.length()) {
                val item = arr.getJSONObject(i)
                if (item.optString("id") == inboxId) {
                    item.put("response",               response)
                    item.put("responseSentToTelegram", sentToTelegram)
                    item.put("responseReadAt",         System.currentTimeMillis())
                    break
                }
            }
            prefs.edit().putString(key, arr.toString()).apply()
        } catch (e: Exception) { /* ignore */ }
    }

    // ── Notifications ──────────────────────────────────────────

    private fun showProcessingNotification(context: Context, isEgo: Boolean, timeStr: String) {
        ensureChannels(context)
        val channelId = if (isEgo) CHANNEL_EGO else CHANNEL_JOSH
        val emoji     = if (isEgo) "🧠" else "💪"
        val name      = if (isEgo) "Ego" else "Josh"
        val notif = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle("$emoji Generating response...")
            .setContentText("$name ka $timeStr wala response generate ho raha hai, thoda wait karo...")
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .build()
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(if (isEgo) 7000001 else 7000002, notif)
    }

    private fun showSuccessNotification(context: Context, isEgo: Boolean, timeStr: String, sentToTelegram: Boolean) {
        ensureChannels(context)
        val channelId = if (isEgo) CHANNEL_EGO else CHANNEL_JOSH
        val emoji     = if (isEgo) "🧠" else "💪"
        val name      = if (isEgo) "Ego" else "Josh"
        val title = if (sentToTelegram) "$emoji Response sent to Telegram ✅"
                    else "$emoji $name response ready (Telegram not configured)"
        val body  = if (sentToTelegram) "$name ka $timeStr wala full response ab telegram pe mil jayega!"
                    else "Response ready hai — inbox mein ja kar dekho. Telegram ke liye settings mein bot token add karo."
        val notif = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .build()
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(if (isEgo) 7000001 else 7000002)
        nm.notify(if (isEgo) 7000003 else 7000004, notif)
    }

    private fun showErrorNotification(context: Context, isEgo: Boolean, timeStr: String) {
        ensureChannels(context)
        val channelId = if (isEgo) CHANNEL_EGO else CHANNEL_JOSH
        val name      = if (isEgo) "🧠 Ego" else "💪 Josh"
        val notif = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle("$name response failed")
            .setContentText("API call failed. App kholo aur inbox se manually read kar sakte ho.")
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .build()
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(if (isEgo) 7000001 else 7000002)
        nm.notify(if (isEgo) 7000005 else 7000006, notif)
    }

    private fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(
                android.app.NotificationChannel(CHANNEL_EGO, "Ego AI Reports", NotificationManager.IMPORTANCE_HIGH)
            )
            nm.createNotificationChannel(
                android.app.NotificationChannel(CHANNEL_JOSH, "Josh Reminders", NotificationManager.IMPORTANCE_HIGH)
            )
        }
    }

    private fun todayStr(): String {
        val c = Calendar.getInstance()
        return String.format("%04d-%02d-%02d", c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1, c.get(Calendar.DAY_OF_MONTH))
    }
}
