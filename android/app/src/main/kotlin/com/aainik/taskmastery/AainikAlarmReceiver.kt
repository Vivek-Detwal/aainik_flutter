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
import org.json.JSONArray
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
        const val CHANNEL_JOSH  = "aainik-josh"

        private val EGO_NOTIF_TEMPLATES = arrayOf(
            "🧠 Ego ne teri {TIME} bje tk ki progress dekh li hai • 'Send me ego\\'s response' pe click kar — main tujhe pura response telegram pe bhejta hun",
            "🧠 {TIME} ka Ego check ho chuka — click karo, main poora analysis telegram pe bhejta hun",
            "🧠 Bhai {TIME} ho gaya — Ego ki nazar mein hai sab kuch • ek click se telegram pe pura response",
            "🧠 Ego alert {TIME}: tera progress dekh liya — response manga lo, click karo",
            "🧠 {TIME} wala Ego observation complete — telegram pe bhejun? click karo",
            "🧠 Real talk from Ego — {TIME} check complete • click for full response on telegram",
            "🧠 {TIME}: Ego ne tera kaam dekh liya — poora feedback telegram pe aayega, click karo",
            "🧠 Ego ka {TIME} checkpoint ready — ek click pe telegram pe pura jawab",
            "🧠 {TIME} check in: Ego ke paas tera full analysis hai — telegram pe maango, click karo",
            "🧠 {TIME} — Ego teri performance pe nazar rakh raha tha • response lene ke liye click karo"
        )

        private val JOSH_NOTIF_TEMPLATES = arrayOf(
            "💪 Josh ne tere liye {TIME} pe kuchh bheja hai • 'Send me josh\\'s response' pr click kar — main tujhe telegram pr pura response bhejta hun",
            "💪 {TIME} wala Josh ka message ready hai — click karo main telegram pe deliver kar deta hun",
            "💪 Josh tera wait kar raha tha {TIME} pe — abhi click karo full motivation telegram pe pao",
            "💪 {TIME} reminder: Josh ne tera plan dekha — click karo, telegram pe fire mile",
            "💪 Josh ka {TIME} session tayaar hai — bhai click kar aur josh feel kar telegram pe",
            "💪 {TIME}: Josh has your back — click for full motivation on telegram",
            "💪 Josh ne {TIME} pe teri preparation dekhi — poora response telegram pe manga lo",
            "💪 {TIME} Josh check-in — full hype on the way, click karo aur telegram pe pao",
            "💪 Josh ka {TIME} wala jawab ready hai — ek click pe telegram pe aayega, sun lo",
            "💪 {TIME} — Josh poori fire ke saath ready tha • click for full response on telegram"
        )
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

        if (isEgo) showEgoNotification(context, hour, minute, timeStr, dataJson, alarmId)
        else       showJoshNotification(context, hour, minute, timeStr, dataJson, alarmId)
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
        context: Context, hour: Int, minute: Int, timeStr: String, dataJson: String?, alarmId: Int
    ) {
        ensureChannels(context)

        // Check if ego auto-coach is enabled
        if (dataJson != null) {
            try {
                val data     = JSONObject(dataJson)
                val settings = data.optJSONObject("settings") ?: JSONObject()
                if (!settings.optBoolean("autoCoachEnabled", false)) return
            } catch (e: Exception) { /* proceed with defaults */ }
        }

        // Pick template using alarmId % 10
        val templateIdx  = Math.abs(alarmId % 10)
        val templateText = EGO_NOTIF_TEMPLATES[templateIdx].replace("{TIME}", timeStr)

        // Generate inbox ID and save item to SharedPreferences
        val inboxId = "ego_inbox_${todayStr()}_${timeStr.replace(":", "")}_$alarmId"
        addToInbox(context, true, inboxId, timeStr, templateText)

        // Action button PendingIntent (fires NotificationActionReceiver — no app open needed)
        val actionIntent = Intent(context, NotificationActionReceiver::class.java).apply {
            action = NotificationActionReceiver.ACTION_SEND_EGO_RESPONSE
            putExtra(NotificationActionReceiver.EXTRA_HOUR, hour)
            putExtra(NotificationActionReceiver.EXTRA_MINUTE, minute)
            putExtra(NotificationActionReceiver.EXTRA_ALARM_ID, alarmId)
            putExtra(NotificationActionReceiver.EXTRA_INBOX_ID, inboxId)
        }
        val actionPi = PendingIntent.getBroadcast(
            context, alarmId + 10000, actionIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Tap-on-notification opens the app
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val pi = PendingIntent.getActivity(
            context, 8000000 + alarmId, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notif = NotificationCompat.Builder(context, CHANNEL_EGO)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle("🧠 Ego Reality Check — $timeStr")
            .setContentText(templateText)
            .setStyle(NotificationCompat.BigTextStyle().bigText(templateText))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setTicker("Ego Reality Check")
            .addAction(0, "Send me ego's response", actionPi)
            .build()

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(8000000 + alarmId, notif)
    }

    // ── Josh Notification ──────────────────────────────────────
    private fun showJoshNotification(
        context: Context, hour: Int, minute: Int, timeStr: String, dataJson: String?, alarmId: Int
    ) {
        ensureChannels(context)

        // Check if josh auto is enabled
        if (dataJson != null) {
            try {
                val data     = JSONObject(dataJson)
                val settings = data.optJSONObject("settings") ?: JSONObject()
                if (!settings.optBoolean("joshAutoEnabled", false)) return
            } catch (e: Exception) { /* proceed with defaults */ }
        }

        // Pick template using alarmId % 10
        val templateIdx  = Math.abs(alarmId % 10)
        val templateText = JOSH_NOTIF_TEMPLATES[templateIdx].replace("{TIME}", timeStr)

        // Generate inbox ID and save item to SharedPreferences
        val inboxId = "josh_inbox_${todayStr()}_${timeStr.replace(":", "")}_$alarmId"
        addToInbox(context, false, inboxId, timeStr, templateText)

        // Action button PendingIntent
        val actionIntent = Intent(context, NotificationActionReceiver::class.java).apply {
            action = NotificationActionReceiver.ACTION_SEND_JOSH_RESPONSE
            putExtra(NotificationActionReceiver.EXTRA_HOUR, hour)
            putExtra(NotificationActionReceiver.EXTRA_MINUTE, minute)
            putExtra(NotificationActionReceiver.EXTRA_ALARM_ID, alarmId)
            putExtra(NotificationActionReceiver.EXTRA_INBOX_ID, inboxId)
        }
        val actionPi = PendingIntent.getBroadcast(
            context, alarmId + 10000, actionIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Tap-on-notification opens the app
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val pi = PendingIntent.getActivity(
            context, 9000000 + alarmId, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notif = NotificationCompat.Builder(context, CHANNEL_JOSH)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle("💪 Josh Reminder — $timeStr")
            .setContentText(templateText)
            .setStyle(NotificationCompat.BigTextStyle().bigText(templateText))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setTicker("Josh Reminder")
            .addAction(0, "Send me josh's response", actionPi)
            .build()

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(9000000 + alarmId, notif)
    }

    // ── Add item to inbox in SharedPreferences ─────────────────
    private fun addToInbox(context: Context, isEgo: Boolean, inboxId: String, timeStr: String, notifText: String) {
        try {
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val key   = if (isEgo) "flutter.aainik_ego_inbox_v1" else "flutter.aainik_josh_inbox_v1"
            val existing = prefs.getString(key, "[]") ?: "[]"
            val arr  = JSONArray(existing)
            val item = JSONObject()
            item.put("id",                   inboxId)
            item.put("type",                 if (isEgo) "ego" else "josh")
            item.put("triggerTime",          timeStr)
            item.put("date",                 todayStr())
            item.put("timestamp",            System.currentTimeMillis())
            item.put("notifTitle",           notifText)
            item.put("response",             JSONObject.NULL)
            item.put("responseSentToTelegram", false)
            item.put("responseReadAt",       JSONObject.NULL)

            // Prepend newest first, keep max 30
            val newArr = JSONArray()
            newArr.put(item)
            for (i in 0 until minOf(arr.length(), 29)) newArr.put(arr.get(i))

            prefs.edit().putString(key, newArr.toString()).apply()
        } catch (e: Exception) { /* ignore */ }
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
