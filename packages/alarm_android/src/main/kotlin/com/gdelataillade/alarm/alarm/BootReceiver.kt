package com.gdelataillade.alarm.alarm

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.gdelataillade.alarm.models.AlarmEventCause
import com.gdelataillade.alarm.models.AlarmEventVerb
import com.gdelataillade.alarm.models.AlarmSettings
import com.gdelataillade.alarm.models.HostAlarmEvent
import com.gdelataillade.alarm.services.AlarmStorage
import com.gdelataillade.alarm.api.AlarmApiImpl

class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "BootReceiver"

        /**
         * Whether [alarm] was due so long before [now] that ringing it would be
         * noise rather than a wake-up.
         *
         * A null `androidStaleAfterMillis` never goes stale, which is what an
         * application asks for when the alarm has to ring however late.
         */
        internal fun isStale(alarm: AlarmSettings, now: Long): Boolean {
            val staleAfterMillis = alarm.androidStaleAfterMillis ?: return false
            return now - alarm.dateTime.time > staleAfterMillis
        }

        /**
         * Discards [alarm] and records why, instead of sounding it hours late.
         *
         * Nothing is reported to Dart from here: no Flutter engine is running at
         * boot, which is the whole reason these decisions are recorded durably.
         * The marker is drained on the next `Alarm.init()`.
         */
        internal fun discardStaleAlarm(alarm: AlarmSettings, storage: AlarmStorage, now: Long) {
            val event = HostAlarmEvent(
                alarmId = alarm.id,
                verb = AlarmEventVerb.DROPPED,
                cause = AlarmEventCause.STALE_AT_BOOT,
                atMillis = alarm.dateTime.time,
                recordedAtMillis = now,
            )

            // Same order AlarmService uses when it drops a refused ring:
            // unsaveAlarm deliberately keeps DROPPED markers, so the record
            // outlives the alarm it describes.
            storage.saveAlarmEvent(event)
            storage.unsaveAlarm(alarm.id)

            Log.i(
                TAG,
                "Alarm ${alarm.id} was due at ${alarm.dateTime} and is past its stale " +
                    "window; discarded instead of ringing at boot."
            )
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            Log.d(TAG, "Device rebooted, rescheduling alarms")

            rescheduleAlarms(context)
        }
    }

    private fun rescheduleAlarms(context: Context) {
        val alarmStorage = AlarmStorage(context)
        val storedAlarms = alarmStorage.getSavedAlarms()
        // One reading for the whole batch, so alarms due at the same time are
        // not judged differently because the loop took a moment.
        val now = System.currentTimeMillis()

        Log.i(TAG, "Rescheduling ${storedAlarms.size} alarms")

        for (alarm in storedAlarms) {
            try {
                if (isStale(alarm, now)) {
                    discardStaleAlarm(alarm, alarmStorage, now)
                    continue
                }

                Log.d(TAG, "Rescheduling alarm with ID: ${alarm.id}")
                Log.d(TAG, "Alarm details: $alarm")

                // Call the setAlarm method in AlarmPlugin with the custom context
                val alarmApi = AlarmApiImpl(context)
                if (alarmApi.setAlarm(alarm)) {
                    Log.d(TAG, "Alarm rescheduled successfully for ID: ${alarm.id}")
                } else {
                    // Deliberately left in storage, unlike the Pigeon set path which
                    // unsaves so Dart never reports an alarm the platform never armed.
                    // Here that record is the only thing a later attempt could re-arm
                    // from, and there is no engine running to be told about the
                    // failure — dropping it would silently lose the user's alarm for
                    // good. A boot-time failure is often transient anyway, because the
                    // system is still coming up.
                    Log.e(
                        TAG,
                        "Failed to re-arm alarm ${alarm.id} after reboot. It stays stored " +
                            "so a later Alarm.init() or reboot can retry."
                    )
                }
            } catch (e: Exception) {
                Log.e(TAG, "Exception while rescheduling alarm: $alarm", e)
            }
        }
    }
}