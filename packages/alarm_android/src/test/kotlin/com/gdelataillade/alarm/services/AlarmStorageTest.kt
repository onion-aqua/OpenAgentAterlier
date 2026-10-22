package com.gdelataillade.alarm.services

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.gdelataillade.alarm.models.AlarmEventCause
import com.gdelataillade.alarm.models.AlarmEventVerb
import com.gdelataillade.alarm.models.HostAlarmEvent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The host event marker rules.
 *
 * These were previously covered only by driving a phone: the upgrade migration
 * needed installing one release over another, and the verb-aware clearing needed
 * a boot. Every rule here is one whose failure is *silent* — the alarm ends up in
 * the right state and the application is simply never told why — which is exactly
 * the kind that survives manual testing.
 */
class AlarmStorageTest {
    @get:Rule
    val tempFolder = TemporaryFolder()

    private lateinit var storage: AlarmStorage
    private lateinit var dataStore: DataStore<Preferences>

    private val day = 24L * 60 * 60 * 1000

    @Before
    fun setUp() {
        dataStore = PreferenceDataStoreFactory.create(
            scope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
        ) { tempFolder.newFile("alarm-test-${System.nanoTime()}.preferences_pb") }
        storage = AlarmStorage(dataStore)
    }

    private fun movedEvent(id: Int, at: Long, recordedAt: Long = at) = HostAlarmEvent(
        alarmId = id,
        verb = AlarmEventVerb.MOVED,
        cause = AlarmEventCause.SNOOZE,
        atMillis = at,
        recordedAtMillis = recordedAt,
    )

    private fun droppedEvent(id: Int, at: Long, recordedAt: Long = at) = HostAlarmEvent(
        alarmId = id,
        verb = AlarmEventVerb.DROPPED,
        cause = AlarmEventCause.STALE_AT_BOOT,
        atMillis = at,
        recordedAtMillis = recordedAt,
    )

    /** Writes a marker in the snooze-only format 5.7.0 through 5.9.0 used. */
    private fun writeLegacySnoozeMarker(id: Int, nextRingAtMillis: Long) = runBlocking {
        dataStore.edit { prefs ->
            prefs[stringPreferencesKey("__snoozed_alarm_id__$id")] =
                nextRingAtMillis.toString()
        }
    }

    private fun rawKeys(): Set<String> = runBlocking {
        var keys = emptySet<String>()
        dataStore.edit { prefs -> keys = prefs.asMap().keys.map { it.name }.toSet() }
        keys
    }

    @Test
    fun `a saved event is read back`() {
        val event = movedEvent(42, System.currentTimeMillis() + 60_000)
        storage.saveAlarmEvent(event)

        assertEquals(listOf(event), storage.getPendingAlarmEvents())
    }

    @Test
    fun `the newest event for an alarm wins`() {
        // One marker per alarm, last write wins: if an alarm is deferred and then
        // discarded, the terminal state is what the application needs.
        val now = System.currentTimeMillis()
        storage.saveAlarmEvent(movedEvent(42, now + 60_000))
        storage.saveAlarmEvent(droppedEvent(42, now, recordedAt = now + 1))

        val pending = storage.getPendingAlarmEvents()

        assertEquals(1, pending.size)
        assertEquals(AlarmEventVerb.DROPPED, pending.single().verb)
    }

    @Test
    fun `unsaveAlarm clears a deferral but keeps a discard`() {
        // The trap. A discard is recorded *by* removing the alarm, so clearing
        // every marker here would delete the very event the application is
        // waiting to be told about — and nothing would look wrong, because the
        // alarm is correctly gone either way.
        val now = System.currentTimeMillis()
        storage.saveAlarmEvent(movedEvent(1, now + 60_000))
        storage.saveAlarmEvent(droppedEvent(2, now))

        storage.unsaveAlarm(1)
        storage.unsaveAlarm(2)

        val pending = storage.getPendingAlarmEvents()
        assertEquals(1, pending.size)
        assertEquals(2, pending.single().alarmId)
        assertEquals(AlarmEventVerb.DROPPED, pending.single().verb)
    }

    @Test
    fun `unsaveAlarm clears a legacy snooze marker`() {
        writeLegacySnoozeMarker(7, System.currentTimeMillis() + 60_000)

        storage.unsaveAlarm(7)

        assertTrue(storage.getPendingAlarmEvents().isEmpty())
    }

    @Test
    fun `a legacy snooze marker reads as a deferral`() {
        // Written by 5.7.0 through 5.9.0. An upgrade must not lose a deferral
        // that was pending when the app was replaced.
        val nextRingAt = System.currentTimeMillis() + 60_000
        writeLegacySnoozeMarker(7, nextRingAt)

        val event = storage.getPendingAlarmEvents().single()

        assertEquals(7, event.alarmId)
        assertEquals(AlarmEventVerb.MOVED, event.verb)
        assertEquals(AlarmEventCause.SNOOZE, event.cause)
        assertEquals(nextRingAt, event.atMillis)
        // Nothing recorded when it was written, so the ring time stands in --
        // which is exactly what the old acknowledgement compared against.
        assertEquals(nextRingAt, event.recordedAtMillis)
    }

    @Test
    fun `acknowledging a legacy marker removes it`() {
        val nextRingAt = System.currentTimeMillis() + 60_000
        writeLegacySnoozeMarker(7, nextRingAt)

        storage.acknowledgeAlarmEvent(7, nextRingAt)

        assertTrue(storage.getPendingAlarmEvents().isEmpty())
    }

    @Test
    fun `acknowledging matches on the recorded time`() {
        val now = System.currentTimeMillis()
        storage.saveAlarmEvent(movedEvent(42, now + 60_000, recordedAt = now))

        storage.acknowledgeAlarmEvent(42, now)

        assertTrue(storage.getPendingAlarmEvents().isEmpty())
    }

    @Test
    fun `a late acknowledgement cannot discard a newer event`() {
        // The guard that keeps a second deferral from being thrown away by the
        // reply to the first one.
        val now = System.currentTimeMillis()
        storage.saveAlarmEvent(movedEvent(42, now + 60_000, recordedAt = now))
        storage.saveAlarmEvent(movedEvent(42, now + 120_000, recordedAt = now + 500))

        storage.acknowledgeAlarmEvent(42, now)

        val pending = storage.getPendingAlarmEvents()
        assertEquals(1, pending.size)
        assertEquals(now + 500, pending.single().recordedAtMillis)
    }

    @Test
    fun `a deferral survives longer than a discard`() {
        // Per-verb TTL: the alarm behind a deferral is still owed, while a
        // missed-alarm notice surfacing days later is only noise.
        val now = System.currentTimeMillis()
        storage.saveAlarmEvent(movedEvent(1, now - 3 * day))
        storage.saveAlarmEvent(droppedEvent(2, now - 3 * day))

        val pending = storage.getPendingAlarmEvents().associateBy { it.alarmId }

        assertNotNull("a 3-day-old deferral is still applicable", pending[1])
        assertNull("a 3-day-old discard is stale", pending[2])
    }

    @Test
    fun `a discard recorded now survives an alarm that was due days ago`() {
        // The TTL is how long a notice stays worth delivering, not how old the
        // alarm was. A discard at boot always describes a due time that has
        // passed — that is what made it stale — so ageing it by that time would
        // expire the marker the moment it was written.
        val now = System.currentTimeMillis()
        storage.saveAlarmEvent(droppedEvent(2, now - 3 * day, recordedAt = now))

        assertNotNull(storage.getPendingAlarmEvents().firstOrNull { it.alarmId == 2 })
    }

    @Test
    fun `a discard recorded more than a day ago is still pruned`() {
        // The TTL still has to bite, or a marker Dart never applies lives forever.
        val now = System.currentTimeMillis()
        storage.saveAlarmEvent(droppedEvent(2, now - 3 * day, recordedAt = now - 2 * day))

        assertTrue(storage.getPendingAlarmEvents().isEmpty())
    }

    @Test
    fun `an ancient deferral is pruned`() {
        storage.saveAlarmEvent(movedEvent(1, System.currentTimeMillis() - 8 * day))

        assertTrue(storage.getPendingAlarmEvents().isEmpty())
    }

    @Test
    fun `an expired marker is deleted rather than merely hidden`() {
        // Otherwise a marker Dart can never apply accumulates forever.
        storage.saveAlarmEvent(movedEvent(1, System.currentTimeMillis() - 8 * day))

        storage.getPendingAlarmEvents()

        assertTrue(rawKeys().none { it.startsWith("__alarm_event__") })
    }

    @Test
    fun `an unreadable marker is dropped instead of failing the whole read`() {
        // One corrupt row must not cost the application every other event.
        val good = movedEvent(1, System.currentTimeMillis() + 60_000)
        storage.saveAlarmEvent(good)
        runBlocking {
            dataStore.edit { prefs ->
                prefs[stringPreferencesKey("__alarm_event__999")] = "not json"
            }
        }

        assertEquals(listOf(good), storage.getPendingAlarmEvents())
        assertTrue(rawKeys().none { it == "__alarm_event__999" })
    }

    @Test
    fun `clearAlarmEvent removes both marker formats`() {
        val now = System.currentTimeMillis()
        storage.saveAlarmEvent(movedEvent(1, now + 60_000))
        writeLegacySnoozeMarker(2, now + 60_000)

        storage.clearAlarmEvent(1)
        storage.clearAlarmEvent(2)

        assertTrue(storage.getPendingAlarmEvents().isEmpty())
    }
}
