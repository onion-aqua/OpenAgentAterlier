package com.gdelataillade.alarm.alarm

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import com.gdelataillade.alarm.services.AlarmStorage
import com.gdelataillade.alarm.services.NotificationHandler
import com.gdelataillade.alarm.services.SnoozeCoordinator

import io.flutter.Log

class AlarmReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "AlarmReceiver"

        const val ACTION_ALARM_STOP = "com.gdelataillade.alarm.ACTION_STOP"
        const val ACTION_ALARM_SNOOZE = "com.gdelataillade.alarm.ACTION_SNOOZE"
        const val ACTION_ALARM_RESTORE = "com.gdelataillade.alarm.ACTION_RESTORE"
    }

    override fun onReceive(context: Context, intent: Intent) {
        // Stop alarm from the notification stop button or notification dismissal.
        if (intent.action == ACTION_ALARM_STOP) {
            val id = intent.getIntExtra("id", 0)
            Log.d(TAG, "Received stop alarm command from notification, id: $id")

            val service = AlarmService.instance
            if (service != null) {
                service.handleStopAlarmCommand(id)
            } else if (id != 0) {
                // The service is not running anymore (e.g. it was killed while
                // the notification lingered). Clean up directly instead of
                // starting the foreground service, which would crash because
                // a stop command never calls startForeground().
                AlarmStorage(context).unsaveAlarm(id)
                // The ongoing notification is not owned by a foreground service
                // here, so it must be cancelled explicitly or it lingers.
                NotificationHandler(context).cancelNotification(id)
                AlarmPlugin.alarmTriggerApi?.alarmStopped(id.toLong()) {
                    Log.d(TAG, "Alarm stopped notification for $id processed by Flutter: ${it.isSuccess}")
                }
            }
            return
        }

        // Put the notification back after the user swiped it away, which is what
        // androidStopAlarmOnDismiss = false means: the swipe must not be able to
        // silence the alarm, and it must not be able to take away the controls
        // either. The service decides whether the alarm is still ringing.
        if (intent.action == ACTION_ALARM_RESTORE) {
            val id = intent.getIntExtra("id", 0)
            Log.d(TAG, "Received restore notification command, id: $id")
            if (id != 0) AlarmService.instance?.restoreNotification(id)
            return
        }

        // Defer the alarm from the notification's snooze action.
        if (intent.action == ACTION_ALARM_SNOOZE) {
            val id = intent.getIntExtra("id", 0)
            Log.d(TAG, "Received snooze alarm command, id: $id")
            // Handled through the coordinator rather than the service, which may
            // have been killed while its notification lingered. Going through
            // AlarmService.instance? here would make the snooze a silent no-op
            // in exactly that case: notification left up, alarm never
            // rescheduled, nothing reported.
            SnoozeCoordinator.snooze(context, id)
            return
        }

        // Start the alarm service to ring the alarm.
        val alarmId = intent.getIntExtra("id", 0)
        val serviceIntent = Intent(context, AlarmService::class.java)
        serviceIntent.putExtras(intent)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Use the alarm id as request code so alarms firing in the same
            // moment never overwrite each other's pending intent extras.
            val pendingIntent = PendingIntent.getForegroundService(
                context,
                alarmId,
                serviceIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            pendingIntent.send()
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }
    }
}
