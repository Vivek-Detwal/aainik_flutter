package com.aainik.taskmastery

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import java.util.Calendar

class AainikAlarmReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_EGO   = "com.aainik.taskmastery.EGO_ALARM"
        const val ACTION_JOSH  = "com.aainik.taskmastery.JOSH_ALARM"
        const val EXTRA_HOUR   = "hour"
        const val EXTRA_MINUTE = "minute"
        const val EXTRA_ALARM_ID = "alarm_id"
        const val CHANNEL_EGO  = "aainik-ego"
        const val CHANNEL_JOSH = "aainik-josh"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return

        // ── Boot completed: reschedule all alarms ──────────────
        if (action == Intent.ACTION_BOOT_COMPLETED ||
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == "com.htc.intent.action.QUICKBOOT_POWERON" ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            rescheduleAllOnBoot(context)
            return
        }

        val hour    = intent.getIntExtra(EXTRA_HOUR, 0)
        val minute  = intent.getIntExtra(EXTRA_MINUTE, 0)
        val alarmId = intent.getIntExtra(EXTRA_ALARM_ID, 0)
        val timeStr = String.format("%02d:%02d", hour, minute)
        val isEgo   = action == ACTION_EGO

        // ── Step 1: Reschedule for tomorrow FIRST ──────────────
        rescheduleForTomorrow(context, hour, minute, alarmId, isEgo)

        // ── Step 2: Show notification using local data ─────────
        val prefs    = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val dataJson = prefs.getString("flutter.aainik_app_data_v1", null)

        if (isEgo) showEgoNotification(context, timeStr, dataJson, alarmId)
        else       showJoshNotification(context, timeStr, dataJson, alarmId)
    }

    // ── Reschedule for tomorrow ────────────────────────────────
    private fun rescheduleForTomorrow(
        context: Context, hour: Int, minute: Int, alarmId: Int, isEgo: Boolean
    ) {
        try {
            val cal = Calendar.getInstance()
            cal.add(Calendar.DAY_OF_YEAR, 1)
            cal.set(Calendar.HOUR_OF_DAY, hour)
            cal.set(Calendar.MINUTE, minute)
            cal.set(Calendar.SECOND, 0)
            cal.set(Calendar.MILLISECOND, 0)
            scheduleAt(context, cal.timeInMillis, hour, minute, alarmId, isEgo)
        } catch (e: Exception) { /* ignore */ }
    }

    // ── Reschedule all on boot ─────────────────────────────────
    private fun rescheduleAllOnBoot(context: Context) {
        try {
            val prefs     = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val schedJson = prefs.getString("flutter.aainik_scheduled_alarms_v2", null) ?: return
            val schedule  = JSONObject(schedJson)
            val am        = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

            val egoArr  = schedule.optJSONArray("ego")
            val joshArr = schedule.optJSONArray("josh")

            egoArr?.let {
                for (i in 0 until it.length()) scheduleFromTimeStr(context, am, it.getString(i), true)
            }
            joshArr?.let {
                for (i in 0 until it.length()) scheduleFromTimeStr(context, am, it.getString(i), false)
            }
        } catch (e: Exception) { /* ignore */ }
    }

    private fun scheduleFromTimeStr(context: Context, am: AlarmManager, time: String, isEgo: Boolean) {
        val parts  = time.split(":")
        if (parts.size != 2) return
        val hour   = parts[0].toIntOrNull() ?: return
        val minute = parts[1].toIntOrNull() ?: return
        val id     = if (isEgo) 10000 + hour * 60 + minute else 20000 + hour * 60 + minute

        val cal = Calendar.getInstance()
        cal.set(Calendar.HOUR_OF_DAY, hour)
        cal.set(Calendar.MINUTE, minute)
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        if (cal.timeInMillis <= System.currentTimeMillis()) cal.add(Calendar.DAY_OF_YEAR, 1)
        scheduleAt(context, cal.timeInMillis, hour, minute, id, isEgo)
    }

    private fun scheduleAt(
        context: Context, triggerMs: Long, hour: Int, minute: Int, alarmId: Int, isEgo: Boolean
    ) {
        val intent = Intent(context, AainikAlarmReceiver::class.java).apply {
            action = if (isEgo) ACTION_EGO else ACTION_JOSH
            putExtra(EXTRA_HOUR, hour)
            putExtra(EXTRA_MINUTE, minute)
            putExtra(EXTRA_ALARM_ID, alarmId)
        }
        val pi = PendingIntent.getBroadcast(
            context, alarmId, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        // setAlarmClock = highest priority, same as phone's clock app alarm
        val showIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val showPi = PendingIntent.getActivity(
            context, alarmId + 5000, showIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        am.setAlarmClock(AlarmManager.AlarmClockInfo(triggerMs, showPi), pi)
    }

    // ── Ego Notification ───────────────────────────────────────
    private fun showEgoNotification(
        context: Context, timeStr: String, dataJson: String?, alarmId: Int
    ) {
        ensureChannels(context)

        var title = "🧠 Ego Reality Check — $timeStr"
        var body  = "App khol — Ego ka full report ready hai!"

        if (dataJson != null) {
            try {
                val data     = JSONObject(dataJson)
                val settings = data.optJSONObject("settings") ?: JSONObject()
                if (!settings.optBoolean("autoCoachEnabled", false)) return

                val personality = settings.optString("autoCoachPersonality", "beast")
                val today       = todayStr()
                val tasks       = data.optJSONArray("tasks")
                val history     = data.optJSONArray("history")
                var done = 0; var total = 0
                val pendingNames = mutableListOf<String>()

                if (tasks != null && history != null) {
                    for (i in 0 until tasks.length()) {
                        val t = tasks.getJSONObject(i)
                        if (!t.optBoolean("active", true)) continue
                        val start = t.optString("workingWindowStart",
                            t.optString("scheduledTime", "00:00"))
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
                        if (taskDone) done++ else pendingNames.add(t.optString("name", ""))
                    }
                }

                val pct = if (total > 0) done * 100 / total else 0
                title = when {
                    personality == "beast" && pct == 0 && total > 0 ->
                        "🧠 0% done bhai?! ($done/$total) — koi bahaana nahi!"
                    personality == "beast" && pct >= 80 ->
                        "🧠 $pct% — acha hai! App khol full report ke liye"
                    personality == "beast" ->
                        "🧠 Sirf $pct%? ($done/$total done) — Ego wait kar raha hai!"
                    personality == "balanced" ->
                        "🧠 Reality Check $timeStr — $done/$total tasks ($pct%)"
                    else ->
                        "🧠 Tu aacha kar raha hai — $done/$total done! App khol 💜"
                }
                body = buildEgoBody(pendingNames, done, total, pct, personality)
            } catch (e: Exception) { /* use defaults */ }
        }

        notify(context, 8000000 + alarmId, title, body, CHANNEL_EGO, "Tap to open Tera-Ego")
    }

    private fun buildEgoBody(
        pendingNames: List<String>, done: Int, total: Int, pct: Int, personality: String
    ): String {
        val parts = mutableListOf<String>()
        if (pendingNames.isNotEmpty()) {
            val shown = pendingNames.take(3).joinToString(", ")
            val extra = if (pendingNames.size > 3) " +${pendingNames.size - 3} aur" else ""
            parts.add("⏳ Abhi baki: $shown$extra")
        }
        if (total > 0) parts.add("✅ Done: $done/$total ($pct%)")
        parts.add(when (personality) {
            "beast"    -> "App khol — Ego full roast de raha hai, koi bahaana nahi!"
            "balanced" -> "App khol — Ego full analysis aur next steps ready hain!"
            else       -> "App khol — Ego tujhe encourage karna chahta hai! 💜"
        })
        return parts.joinToString("\n")
    }

    // ── Josh Notification ──────────────────────────────────────
    private fun showJoshNotification(
        context: Context, timeStr: String, dataJson: String?, alarmId: Int
    ) {
        ensureChannels(context)

        var title = "💪 Josh Reminder — $timeStr"
        var body  = "App khol — Josh aaj ke tasks ke saath tera wait kar raha hai!"

        if (dataJson != null) {
            try {
                val data     = JSONObject(dataJson)
                val settings = data.optJSONObject("settings") ?: JSONObject()
                if (!settings.optBoolean("joshAutoEnabled", false)) return

                val personality  = settings.optString("joshPersonality", "energetic")
                val today        = todayStr()
                val tasks        = data.optJSONArray("tasks")
                val history      = data.optJSONArray("history")
                val upcoming     = mutableListOf<String>()
                var done = 0; var total = 0

                if (tasks != null && history != null) {
                    for (i in 0 until tasks.length()) {
                        val t = tasks.getJSONObject(i)
                        if (!t.optBoolean("active", true)) continue
                        val start  = t.optString("workingWindowStart",
                            t.optString("scheduledTime", "00:00"))
                        val taskId = t.optString("id", "")
                        total++
                        var taskDone = false
                        for (j in 0 until history.length()) {
                            val h = history.getJSONObject(j)
                            if (h.optString("taskId") == taskId && h.optString("date") == today) {
                                taskDone = h.optBoolean("completed", false); break
                            }
                        }
                        if (taskDone) done++
                        if (start >= timeStr && !taskDone) upcoming.add(t.optString("name", ""))
                    }
                }

                title = when (personality) {
                    "beast" -> "💪 CHAL UTH JA — $timeStr | ${upcoming.size} tasks abhi baki!"
                    "calm"  -> "💪 Josh ka $timeStr Reminder — ek ek kaam, aage badh"
                    else    -> "💪 Josh reminder — $timeStr | Tu kar sakta hai! 🔥"
                }
                body = if (upcoming.isNotEmpty())
                    "📋 ${upcoming.take(4).joinToString(" • ")}\nAaj: $done/$total done — App khol!"
                else
                    "Sab tasks ho gaye — App khol, kal ka plan banao! 🎯"
            } catch (e: Exception) { /* use defaults */ }
        }

        notify(context, 9000000 + alarmId, title, body, CHANNEL_JOSH, "Tap to open Tera-Josh")
    }

    // ── Helpers ────────────────────────────────────────────────
    private fun notify(
        context: Context, id: Int, title: String, body: String,
        channelId: String, ticker: String
    ) {
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val pi = PendingIntent.getActivity(
            context, id, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notif = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setTicker(ticker)
            .build()

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(id, notif)
    }

    private fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_EGO, "Ego AI Reports",
                    NotificationManager.IMPORTANCE_HIGH).apply { enableVibration(true) }
            )
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_JOSH, "Josh Reminders",
                    NotificationManager.IMPORTANCE_HIGH).apply { enableVibration(true) }
            )
        }
    }

    private fun todayStr(): String {
        val c = Calendar.getInstance()
        return String.format("%04d-%02d-%02d",
            c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1, c.get(Calendar.DAY_OF_MONTH))
    }
}
