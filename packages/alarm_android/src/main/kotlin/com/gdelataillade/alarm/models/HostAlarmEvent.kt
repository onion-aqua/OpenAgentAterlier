package com.gdelataillade.alarm.models

import com.gdelataillade.alarm.generated.AlarmEventCauseWire
import com.gdelataillade.alarm.generated.AlarmEventVerbWire
import com.gdelataillade.alarm.generated.AlarmEventWire
import kotlinx.serialization.Serializable

/**
 * What the host did to an alarm without the application asking.
 *
 * Dart's handling depends only on this. The cause is metadata for the app.
 */
@Serializable
enum class AlarmEventVerb {
    /** The alarm is still owed and is now registered for a different time. */
    MOVED,

    /** The alarm is gone and will not ring. */
    DROPPED,
}

/** Why the host changed an alarm. */
@Serializable
enum class AlarmEventCause {
    /** The user deferred the alarm from the notification or the ring screen. */
    SNOOZE,

    /** The platform refused to let the ring start, so it was re-armed later. */
    PLATFORM_REFUSAL,

    /** The alarm was already past due when the device booted. */
    STALE_AT_BOOT,
}

/**
 * A decision the host took about an alarm while no Flutter engine was running.
 *
 * Held durably by [com.gdelataillade.alarm.services.AlarmStorage] until Dart
 * acknowledges it, because the contexts that take these decisions — a
 * notification action, a full screen intent, `BootReceiver` — usually have no
 * engine to call into.
 */
@Serializable
data class HostAlarmEvent(
    val alarmId: Int,
    val verb: AlarmEventVerb,
    val cause: AlarmEventCause,
    /** For [AlarmEventVerb.MOVED] when it now rings; for DROPPED when it should have. */
    val atMillis: Long,
    /** When this was recorded, so exactly this event can be acknowledged. */
    val recordedAtMillis: Long,
) {
    /**
     * Converts to the datatype used for host platform communication.
     *
     * Kept separate from the stored form on purpose: the stored form is
     * serialized to disk and has to stay readable across plugin versions, while
     * the wire form is regenerated whenever the Pigeon schema changes.
     */
    fun toWire(): AlarmEventWire = AlarmEventWire(
        alarmId = alarmId.toLong(),
        verb = when (verb) {
            AlarmEventVerb.MOVED -> AlarmEventVerbWire.MOVED
            AlarmEventVerb.DROPPED -> AlarmEventVerbWire.DROPPED
        },
        cause = when (cause) {
            AlarmEventCause.SNOOZE -> AlarmEventCauseWire.SNOOZE
            AlarmEventCause.PLATFORM_REFUSAL -> AlarmEventCauseWire.PLATFORM_REFUSAL
            AlarmEventCause.STALE_AT_BOOT -> AlarmEventCauseWire.STALE_AT_BOOT
        },
        atMillis = atMillis,
        recordedAtMillis = recordedAtMillis,
    )
}
