package com.gdelataillade.alarm.models

import com.gdelataillade.alarm.generated.AlarmEventCauseWire
import com.gdelataillade.alarm.generated.AlarmEventVerbWire
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The stored and wire forms of a host alarm event.
 *
 * Both matter beyond the obvious: the stored form is written to disk and has to
 * stay readable by later plugin versions, and the wire form is what Dart decides
 * behaviour from — a verb mapped to the wrong case would silently turn a
 * deferral into a discard.
 */
class HostAlarmEventTest {
    private val event = HostAlarmEvent(
        alarmId = 42,
        verb = AlarmEventVerb.MOVED,
        cause = AlarmEventCause.PLATFORM_REFUSAL,
        atMillis = 1_786_086_270_257,
        recordedAtMillis = 1_786_086_270_589,
    )

    @Test
    fun `toWire carries every field across`() {
        val wire = event.toWire()

        assertEquals(42L, wire.alarmId)
        assertEquals(AlarmEventVerbWire.MOVED, wire.verb)
        assertEquals(AlarmEventCauseWire.PLATFORM_REFUSAL, wire.cause)
        assertEquals(1_786_086_270_257, wire.atMillis)
        assertEquals(1_786_086_270_589, wire.recordedAtMillis)
    }

    @Test
    fun `toWire maps every verb and cause to its own case`() {
        // Guards against a mapping that compiles but collapses two cases into
        // one, which Dart would read as the wrong thing having happened.
        for (verb in AlarmEventVerb.entries) {
            val mapped = event.copy(verb = verb).toWire().verb
            assertEquals(verb.name, mapped.name)
        }
        for (cause in AlarmEventCause.entries) {
            val mapped = event.copy(cause = cause).toWire().cause
            assertEquals(cause.name, mapped.name)
        }
    }

    @Test
    fun `the stored form round trips`() {
        val decoded = Json.decodeFromString<HostAlarmEvent>(Json.encodeToString(event))

        assertEquals(event, decoded)
    }

    @Test
    fun `the stored form is the one already on disk`() {
        // Pinned deliberately: this exact JSON is what 5.10.0 wrote, and a
        // rename of any field would leave markers written by it unreadable
        // after an upgrade — losing a deferral or a missed-alarm notice.
        val onDisk = """{"alarmId":42,"verb":"MOVED","cause":"PLATFORM_REFUSAL",""" +
            """"atMillis":1786086270257,"recordedAtMillis":1786086270589}"""

        assertEquals(event, Json.decodeFromString<HostAlarmEvent>(onDisk))
    }
}
