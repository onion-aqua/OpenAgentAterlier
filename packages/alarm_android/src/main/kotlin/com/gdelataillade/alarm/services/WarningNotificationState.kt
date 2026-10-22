package com.gdelataillade.alarm.services

import android.content.Context
import android.content.Intent
import io.flutter.Log

/**
 * Keeps [NotificationOnKillService] in step with the stored alarms.
 *
 * The invariant is simply: the warning runs when at least one stored alarm asked
 * for it. Enforcing that from one place matters because the alarm set changes
 * from contexts that have no Flutter engine — a snooze taken from a notification
 * reschedules an alarm, and previously nothing re-armed the warning afterwards,
 * so killing the app during a snooze produced no warning at all.
 *
 * The title and body are persisted rather than held in memory for the same
 * reason: the process that needs them is often not the one that was told them.
 */
object WarningNotificationState {
    private const val TAG = "WarningNotificationState"

    private const val DEFAULT_TITLE = "Your alarms may not ring"
    private const val DEFAULT_BODY =
        "You killed the app. Please reopen so your alarms can be rescheduled."

    /** Records the text to show, so any later context can reproduce it. */
    fun setText(context: Context, title: String, body: String) {
        AlarmStorage(context).saveWarningNotificationText(title, body)
    }

    /** Starts or stops the warning to match the currently stored alarms. */
    fun refresh(context: Context) {
        val storage = AlarmStorage(context)
        val wanted = storage.getSavedAlarms().any { it.warningNotificationOnKill }
        if (wanted) turnOn(context, storage) else turnOff(context)
    }

    /** Stops the warning regardless of what the stored alarms ask for. */
    fun disable(context: Context) = turnOff(context)

    private fun turnOn(context: Context, storage: AlarmStorage) {
        if (NotificationOnKillService.isRunning) {
            Log.d(TAG, "Warning notification is already turned on.")
            return
        }

        val (title, body) = storage.getWarningNotificationText()
            ?: (DEFAULT_TITLE to DEFAULT_BODY)

        val serviceIntent = Intent(context, NotificationOnKillService::class.java)
        serviceIntent.putExtra("title", title)
        serviceIntent.putExtra("body", body)

        context.startService(serviceIntent)
        Log.d(TAG, "Warning notification turned on.")
    }

    private fun turnOff(context: Context) {
        if (!NotificationOnKillService.isRunning) {
            Log.d(TAG, "Warning notification is already turned off.")
            return
        }

        context.stopService(Intent(context, NotificationOnKillService::class.java))
        Log.d(TAG, "Warning notification turned off.")
    }
}
