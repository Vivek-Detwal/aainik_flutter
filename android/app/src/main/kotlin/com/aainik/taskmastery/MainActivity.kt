package com.aainik.taskmastery

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Calendar

class MainActivity : FlutterActivity() {

    private val CHANNEL = "aainik/alarm"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "schedule" -> {
                        val hour    = call.argument<Int>("hour")    ?: 0
                        val minute  = call.argument<Int>("minute")  ?: 0
                        val alarmId = call.argument<Int>("alarmId") ?: 0
                        val isEgo   = call.argument<Boolean>("isEgo") ?: true
                        scheduleNativeAlarm(hour, minute, alarmId, isEgo)
                        result.success(true)
                    }
                    "cancel" -> {
                        val alarmId = call.argument<Int>("alarmId") ?: 0
                        val isEgo   = call.argument<Boolean>("isEgo") ?: true
                        cancelNativeAlarm(alarmId, isEgo)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun scheduleNativeAlarm(hour: Int, minute: Int, alarmId: Int, isEgo: Boolean) {
        val cal = Calendar.getInstance()
        cal.set(Calendar.HOUR_OF_DAY, hour)
        cal.set(Calendar.MINUTE, minute)
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        if (cal.timeInMillis <= System.currentTimeMillis()) {
            cal.add(Calendar.DAY_OF_YEAR, 1)
        }

        val intent = Intent(this, AainikAlarmReceiver::class.java).apply {
            action = if (isEgo) AainikAlarmReceiver.ACTION_EGO else AainikAlarmReceiver.ACTION_JOSH
            putExtra(AainikAlarmReceiver.EXTRA_HOUR, hour)
            putExtra(AainikAlarmReceiver.EXTRA_MINUTE, minute)
            putExtra(AainikAlarmReceiver.EXTRA_ALARM_ID, alarmId)
        }
        val pi = PendingIntent.getBroadcast(
            this, alarmId, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // setAlarmClock = highest priority alarm (same as phone's clock app)
        val showIntent = packageManager.getLaunchIntentForPackage(packageName)
        val showPi = PendingIntent.getActivity(
            this, alarmId + 5000, showIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val am = getSystemService(ALARM_SERVICE) as AlarmManager
        am.setAlarmClock(AlarmManager.AlarmClockInfo(cal.timeInMillis, showPi), pi)
    }

    private fun cancelNativeAlarm(alarmId: Int, isEgo: Boolean) {
        val intent = Intent(this, AainikAlarmReceiver::class.java).apply {
            action = if (isEgo) AainikAlarmReceiver.ACTION_EGO else AainikAlarmReceiver.ACTION_JOSH
        }
        val pi = PendingIntent.getBroadcast(
            this, alarmId, intent,
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
        )
        pi?.let { (getSystemService(ALARM_SERVICE) as AlarmManager).cancel(it) }
    }
}
