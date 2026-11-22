package com.example.spiritual_harbor

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Calendar

class MainActivity : AudioServiceActivity() {
    private var permissionReply: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "harbor/wellbeing/daily")
            .setMethodCallHandler { call, reply ->
                when (call.method) {
                    "isEnabled" -> reply.success(DailyReminderReceiver.enabled(this))
                    "setEnabled" -> {
                        val enabled = call.arguments == true
                        if (
                            enabled &&
                            Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                                PackageManager.PERMISSION_GRANTED
                        ) {
                            permissionReply = reply
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 730)
                        } else {
                            DailyReminderReceiver.setEnabled(this, enabled)
                            reply.success(enabled)
                        }
                    }
                    else -> reply.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 730) {
            val allowed = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
            DailyReminderReceiver.setEnabled(this, allowed)
            permissionReply?.success(allowed)
            permissionReply = null
        }
    }
}

class DailyReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!enabled(context)) return
        schedule(context)
        if (intent.action != alarmAction) return

        val manager = context.getSystemService(NotificationManager::class.java)
        if (!manager.areNotificationsEnabled()) return
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(channel, "每日推送", NotificationManager.IMPORTANCE_DEFAULT)
            )
        }
        val launch = PendingIntent.getActivity(
            context, reminderId, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(context, channel)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        manager.notify(
            reminderId,
            notification
                .setSmallIcon(android.R.drawable.ic_popup_reminder)
                .setContentTitle("心灵港湾")
                .setContentText("早安。今天也可以按自己的节奏来。")
                .setContentIntent(launch)
                .setAutoCancel(true)
                .build()
        )
    }

    companion object {
        private const val channel = "harbor.wellbeing.daily"
        private const val alarmAction = "harbor.wellbeing.DAILY_REMINDER"
        private const val reminderId = 730

        private fun preferences(context: Context) =
            context.getSharedPreferences(channel, Context.MODE_PRIVATE)

        fun enabled(context: Context) = preferences(context).getBoolean("enabled", false)

        fun setEnabled(context: Context, enabled: Boolean) {
            preferences(context).edit().putBoolean("enabled", enabled).apply()
            if (enabled) {
                schedule(context)
            } else {
                context.getSystemService(AlarmManager::class.java).cancel(alarm(context))
                context.getSystemService(NotificationManager::class.java).cancel(reminderId)
            }
        }

        private fun alarm(context: Context) = PendingIntent.getBroadcast(
            context,
            reminderId,
            Intent(context, DailyReminderReceiver::class.java).setAction(alarmAction),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        private fun schedule(context: Context) {
            val next = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, 7)
                set(Calendar.MINUTE, 30)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
                if (timeInMillis <= System.currentTimeMillis()) add(Calendar.DATE, 1)
            }
            context.getSystemService(AlarmManager::class.java)
                .setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next.timeInMillis, alarm(context))
        }
    }
}
