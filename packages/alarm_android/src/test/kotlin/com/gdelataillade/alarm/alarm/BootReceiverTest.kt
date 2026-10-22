package com.gdelataillade.alarm.alarm

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import com.gdelataillade.alarm.models.AlarmEventCause
import com.gdelataillade.alarm.models.AlarmEventVerb
import com.gdelataillade.alarm.models.AlarmSettings
import com.gdelataillade.alarm.models.NotificationSettings
import com.gdelataillade.alarm.models.VolumeSettings
import com.gdelataillade.alarm.services.AlarmStorage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.Date

/**
 * What boot does with an alarm whose time passed while the device was off.
 *
 * Re-arming it unconditionally is what 5.10.0 did, and it means an alarm set
 * for 06:00 blares at 08:00 when the phone is switched on — telling the user
 * nothing they cannot already see, having failed at the one job it had. The
 * decision is taken where no Flutter engine is running, so the only way the
 * application ever learns of it is the durable marker left behind.
 */
class BootReceiverTest {
    @get:Rule
    val tempFolder = TemporaryFolder()

    private lateinit var storage: AlarmStorage
    private lateinit var dataStore: DataStore<Preferences>

    private val minute = 60_000L

    /**
     * Derived from the clock, not a fixed instant.
     *
     * A dropped marker older than a day is pruned on read, so a hard-coded
     * epoch would pass until the day it silently stopped exercising
     * anything.
     */
    private val dueAt = System.currentTimeMillis() - 3 * 60 * minute

    @Before
    fun setUp() {
        dataStore = PreferenceDataStoreFactory.create(
            scope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
        ) { tempFolder.newFile("boot-test-${System.nanoTime()}.preferences_pb") }
        storage = AlarmStorage(dataStore)
    }

    private fun alarm(
        id: Int = 42,
        dueAtMillis: Long = dueAt,
        staleAfterMillis: Long? = AlarmSettings.DEFAULT_STALE_AFTER_MILLIS,
    ) = AlarmSettings(
        id = id,
        dateTime = Date(dueAtMillis),
        assetAudioPath = "assets/alarm.mp3",
        volumeSettings = VolumeSettings(
            volume = null,
            fadeDuration = null,
            fadeSteps = emptyList(),
            volumeEnforced = false,
        ),
        notificationSettings = NotificationSettings(title = "Title", body = "Body"),
        loopAudio = true,
        vibrate = true,
        warningNotificationOnKill = true,
        androidFullScreenIntent = true,
        androidStaleAfterMillis = staleAfterMillis,
    )

    @Test
    fun `an alarm still ahead of now is not stale`() {
        assertFalse(BootReceiver.isStale(alarm(), dueAt - 60 * minute))
    }

    @Test
    fun `an alarm inside its window is not stale`() {
        // The reboot case the window exists for: the phone restarted itself for
        // a system update at 05:58 and was back at 06:02, so the alarm is late
        // but still worth ringing.
        assertFalse(BootReceiver.isStale(alarm(), dueAt + 2 * minute))
        // Exactly at the boundary still rings; the window is how long it stays
        // worth ringing, not the first instant it stops.
        assertFalse(BootReceiver.isStale(alarm(), dueAt + 15 * minute))
    }

    @Test
    fun `an alarm past its window is stale`() {
        assertTrue(BootReceiver.isStale(alarm(), dueAt + 15 * minute + 1))
        assertTrue(BootReceiver.isStale(alarm(), dueAt + 120 * minute))
    }

    @Test
    fun `an alarm that never discards is never stale`() {
        // The escape hatch for an alarm that has to ring however late, and the
        // behaviour of 5.10.0 and earlier for every alarm.
        val never = alarm(staleAfterMillis = null)

        assertFalse(BootReceiver.isStale(never, dueAt + 365 * 24 * 60 * minute))
    }

    @Test
    fun `a longer window set by the alarm is honoured`() {
        val patient = alarm(staleAfterMillis = 4 * 60 * minute)

        assertFalse(BootReceiver.isStale(patient, dueAt + 3 * 60 * minute))
        assertTrue(BootReceiver.isStale(patient, dueAt + 5 * 60 * minute))
    }

    @Test
    fun `a marker for an alarm missed by more than a day still reaches Dart`() {
        // The case the cutoff exists for most: the phone was off for days, so
        // the alarm's own time is long past. Expiring the marker by that time
        // rather than by when it was recorded would delete it before the app
        // ever opened, and the drop the application is promised would be the
        // one thing it never hears about.
        val longMissed = alarm(dueAtMillis = System.currentTimeMillis() - 3 * 24 * 60 * minute)

        BootReceiver.discardStaleAlarm(longMissed, storage, System.currentTimeMillis())

        assertEquals(1, storage.getPendingAlarmEvents().size)
    }

    @Test
    fun `discarding removes the alarm and leaves a marker saying why`() {
        val stale = alarm()
        storage.saveAlarm(stale)
        val now = dueAt + 120 * minute

        BootReceiver.discardStaleAlarm(stale, storage, now)

        // The alarm is gone — nothing will ring — and the only remaining trace
        // is what the application reads on its next init.
        assertEquals(emptyList<AlarmSettings>(), storage.getSavedAlarms())

        val events = storage.getPendingAlarmEvents()
        assertEquals(1, events.size)
        val event = events.single()
        assertEquals(stale.id, event.alarmId)
        assertEquals(AlarmEventVerb.DROPPED, event.verb)
        assertEquals(AlarmEventCause.STALE_AT_BOOT, event.cause)
        // The time it should have rung, not the time it was thrown away, so the
        // application can tell the user which alarm was missed.
        assertEquals(dueAt, event.atMillis)
        assertEquals(now, event.recordedAtMillis)
    }
}
