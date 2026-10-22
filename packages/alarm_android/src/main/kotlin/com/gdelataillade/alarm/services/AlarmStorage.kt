package com.gdelataillade.alarm.services

import com.gdelataillade.alarm.models.AlarmEventCause
import com.gdelataillade.alarm.models.AlarmEventVerb
import com.gdelataillade.alarm.models.AlarmSettings
import com.gdelataillade.alarm.models.HostAlarmEvent

import android.content.Context
import io.flutter.Log
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.json.Json
import kotlinx.serialization.encodeToString

const val SHARED_PREFERENCES_NAME = "AlarmSharedPreferences"

private val Context.dataStore: DataStore<Preferences> by
preferencesDataStore(SHARED_PREFERENCES_NAME)

/**
 * Durable storage for alarms and for the events the host records about them.
 *
 * Takes the `DataStore` rather than building it, so unit tests can hand it one
 * over a temporary file and exercise the marker rules — the migration, the TTLs,
 * the acknowledgement match, the verb-aware clearing — without a device.
 */
class AlarmStorage internal constructor(private val dataStore: DataStore<Preferences>) {
    /** Production entry point: one process-wide store, keyed off the context. */
    constructor(context: Context) : this(context.dataStore)

    companion object {
        private const val TAG = "AlarmStorage"
        private const val PREFIX = "__alarm_id__"
        private const val EVENT_PREFIX = "__alarm_event__"

        /** The snooze-only marker written by 5.7.0 through 5.9.0. Read, never written. */
        private const val LEGACY_SNOOZE_PREFIX = "__snoozed_alarm_id__"

        // How long past its moment a marker Dart never applied is kept before
        // being discarded as unapplicable. A deferral stays valid for a while
        // because the alarm is still owed; a missed-alarm notice surfacing days
        // later is just noise.
        private const val MOVED_MARKER_TTL_MILLIS = 7L * 24 * 60 * 60 * 1000
        private const val DROPPED_MARKER_TTL_MILLIS = 24L * 60 * 60 * 1000

        private const val WARNING_TITLE_KEY = "notificationOnAppKillTitle"
        private const val WARNING_BODY_KEY = "notificationOnAppKillBody"
    }

    fun saveAlarm(alarmSettings: AlarmSettings) {
        return runBlocking {
            val key = stringPreferencesKey("$PREFIX${alarmSettings.id}")
            val value = Json.encodeToString(alarmSettings)
            dataStore.edit { preferences -> preferences[key] = value }
        }
    }

    fun unsaveAlarm(id: Int) {
        return runBlocking {
            val key = stringPreferencesKey("$PREFIX$id")
            val eventKey = stringPreferencesKey("$EVENT_PREFIX$id")
            val legacyKey = stringPreferencesKey("$LEGACY_SNOOZE_PREFIX$id")
            dataStore.edit { preferences ->
                preferences.remove(key)

                // A stopped alarm is no longer owed, so a pending *deferral* for
                // it is moot: left behind it would reappear on the next
                // Alarm.init() and try to resurrect an alarm the user dismissed.
                // Legacy markers are always deferrals.
                preferences.remove(legacyKey)

                // A pending *discard* has to survive, though — the whole point
                // of it is to tell the app about an alarm that is now gone, and
                // discarding is done by unsaving. Deciding on the verb rather
                // than on call order means neither caller has to remember to
                // record the event after unsaving. Getting this wrong would be
                // invisible: the alarm is correctly gone either way, the app
                // just never hears why.
                val verb = preferences[eventKey]?.let { raw ->
                    try {
                        Json.decodeFromString<HostAlarmEvent>(raw).verb
                    } catch (e: Exception) {
                        Log.w(TAG, "Unreadable event marker for $id; removing it.")
                        null
                    }
                }
                if (verb != AlarmEventVerb.DROPPED) preferences.remove(eventKey)
            }
        }
    }

    fun getSavedAlarms(): List<AlarmSettings> {
        return runBlocking {
            val preferences = dataStore.data.map { prefs ->
                prefs.asMap().filterKeys { it.name.startsWith(PREFIX) }
            }.first()

            val alarms = mutableListOf<AlarmSettings>()
            preferences.forEach { (key, value) ->
                if (value is String) {
                    try {
                        val alarm = Json.decodeFromString<AlarmSettings>(value)
                        alarms.add(alarm)
                    } catch (e: Exception) {
                        // Fall back to the lenient parser, which understands
                        // payloads written by older plugin versions, instead
                        // of silently dropping the alarm.
                        try {
                            alarms.add(AlarmSettings.fromJson(value))
                            Log.w(TAG, "Recovered alarm for key ${key.name} with legacy parser.")
                        } catch (e2: Exception) {
                            Log.e(
                                TAG,
                                "Error parsing alarm settings for key ${key.name}: ${e2.message}"
                            )
                        }
                    }
                } else {
                    Log.w(TAG, "Skipping non-alarm preference with key: ${key.name}")
                }
            }
            alarms
        }
    }

    /**
     * Records that the host moved or dropped [event]`.alarmId` on its own.
     *
     * These decisions are normally taken with no Flutter engine running: the
     * notification and the ringing screen are native, and `BootReceiver` runs
     * before any app code. Holding the decision here is what lets the next
     * isolate learn about it instead of finding an alarm that silently changed.
     *
     * One marker per alarm, last write wins. That is deliberate rather than
     * lossy: if an alarm is deferred and later discarded, the terminal state is
     * what the application needs to know.
     */
    fun saveAlarmEvent(event: HostAlarmEvent) {
        return runBlocking {
            val key = stringPreferencesKey("$EVENT_PREFIX${event.alarmId}")
            dataStore.edit { preferences ->
                preferences[key] = Json.encodeToString(event)
            }
        }
    }

    /**
     * Reads every pending host alarm event.
     *
     * Non-destructive on purpose: a marker survives until
     * [acknowledgeAlarmEvent] confirms Dart durably applied it, so a read
     * followed by a crash loses nothing. Markers are dropped once the per-verb
     * TTL has passed, so one Dart can never apply cannot accumulate forever.
     * That is measured from the later of when the event happened and when it
     * was recorded: a deferral ages from the time it now rings, while a discard
     * of an alarm missed days ago ages from the moment it was discarded rather
     * than from a due time that was already long gone.
     *
     * Also reads markers written by 5.7.0–5.9.0 under the old snooze-only key,
     * so an app upgrading with a deferral pending does not lose it. Those carry
     * no record of when they were written, so the ring time doubles as the
     * recorded time — which is exactly what the old acknowledgement compared.
     */
    fun getPendingAlarmEvents(): List<HostAlarmEvent> {
        return runBlocking {
            val stored = dataStore.data.map { prefs ->
                prefs.asMap().filterKeys {
                    it.name.startsWith(EVENT_PREFIX) ||
                        it.name.startsWith(LEGACY_SNOOZE_PREFIX)
                }
            }.first()

            val events = mutableListOf<HostAlarmEvent>()
            val expired = mutableListOf<Preferences.Key<*>>()
            val now = System.currentTimeMillis()

            stored.forEach { (key, value) ->
                val event = readEvent(key, value)
                if (event == null) {
                    Log.w(TAG, "Dropping unreadable alarm event marker: ${key.name}")
                    expired.add(key)
                    return@forEach
                }

                val ttl = when (event.verb) {
                    AlarmEventVerb.MOVED -> MOVED_MARKER_TTL_MILLIS
                    AlarmEventVerb.DROPPED -> DROPPED_MARKER_TTL_MILLIS
                }
                // The later of the two, not atMillis alone: a STALE_AT_BOOT
                // drop describes an alarm whose own time may be days past, so
                // ageing it by that would expire the marker before the
                // application ever ran. A MOVED marker still ages from the time
                // it now rings, which is the later value for a deferral.
                val bornAt = maxOf(event.atMillis, event.recordedAtMillis)
                if (now - bornAt > ttl) {
                    Log.w(TAG, "Dropping ${event.verb} marker for ${event.alarmId}, stale since $bornAt.")
                    expired.add(key)
                } else {
                    events.add(event)
                }
            }

            if (expired.isNotEmpty()) {
                dataStore.edit { preferences ->
                    expired.forEach { preferences.remove(it) }
                }
            }
            events
        }
    }

    /** Parses either marker format, or null when the value is unusable. */
    private fun readEvent(key: Preferences.Key<*>, value: Any?): HostAlarmEvent? {
        val raw = value as? String ?: return null

        if (key.name.startsWith(LEGACY_SNOOZE_PREFIX)) {
            val id = key.name.removePrefix(LEGACY_SNOOZE_PREFIX).toIntOrNull() ?: return null
            val nextRingAt = raw.toLongOrNull() ?: return null
            return HostAlarmEvent(
                alarmId = id,
                verb = AlarmEventVerb.MOVED,
                cause = AlarmEventCause.SNOOZE,
                atMillis = nextRingAt,
                recordedAtMillis = nextRingAt,
            )
        }

        return try {
            Json.decodeFromString<HostAlarmEvent>(raw)
        } catch (e: Exception) {
            Log.e(TAG, "Error parsing alarm event for key ${key.name}: ${e.message}")
            null
        }
    }

    /**
     * Drops the marker for [id], but only if it still records exactly
     * [recordedAtMillis].
     *
     * Comparing the timestamp as well as the id means a late acknowledgement for
     * an earlier event cannot discard a newer one recorded for the same alarm in
     * the meantime.
     */
    fun acknowledgeAlarmEvent(id: Int, recordedAtMillis: Long) {
        return runBlocking {
            val key = stringPreferencesKey("$EVENT_PREFIX$id")
            val legacyKey = stringPreferencesKey("$LEGACY_SNOOZE_PREFIX$id")
            dataStore.edit { preferences ->
                val stored = preferences[key]?.let {
                    try {
                        Json.decodeFromString<HostAlarmEvent>(it)
                    } catch (e: Exception) {
                        null
                    }
                }
                when {
                    stored != null && stored.recordedAtMillis == recordedAtMillis ->
                        preferences.remove(key)
                    // A legacy marker's ring time stands in for its recorded
                    // time, matching what the old acknowledgement compared.
                    preferences[legacyKey] == recordedAtMillis.toString() ->
                        preferences.remove(legacyKey)
                    else ->
                        Log.d(TAG, "Not acknowledging event $id: marker moved on.")
                }
            }
        }
    }

    /**
     * Persists the kill-warning notification text.
     *
     * Held here rather than in memory because the context that has to show the
     * warning is often not the one that was told what it should say — a snooze
     * taken from a notification runs with no engine and no plugin instance.
     */
    fun saveWarningNotificationText(title: String, body: String) {
        return runBlocking {
            dataStore.edit { preferences ->
                preferences[stringPreferencesKey(WARNING_TITLE_KEY)] = title
                preferences[stringPreferencesKey(WARNING_BODY_KEY)] = body
            }
        }
    }

    /** The stored kill-warning text, or null when the app never set any. */
    fun getWarningNotificationText(): Pair<String, String>? {
        return runBlocking {
            val prefs = dataStore.data.first()
            val title = prefs[stringPreferencesKey(WARNING_TITLE_KEY)]
            val body = prefs[stringPreferencesKey(WARNING_BODY_KEY)]
            if (title == null || body == null) null else title to body
        }
    }

    /** Removes any pending event marker for [id], whatever it records. */
    fun clearAlarmEvent(id: Int) {
        return runBlocking {
            val key = stringPreferencesKey("$EVENT_PREFIX$id")
            val legacyKey = stringPreferencesKey("$LEGACY_SNOOZE_PREFIX$id")
            dataStore.edit { preferences ->
                preferences.remove(key)
                preferences.remove(legacyKey)
            }
        }
    }
}
