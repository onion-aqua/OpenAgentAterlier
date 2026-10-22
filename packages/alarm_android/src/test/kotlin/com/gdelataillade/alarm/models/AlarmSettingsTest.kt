package com.gdelataillade.alarm.models

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Date

/**
 * How `androidStaleAfterMillis` survives storage.
 *
 * Three states have to stay apart across a restart, and only two of them are
 * obvious. Absent means an alarm saved before the cutoff existed, which has to
 * take the default so an upgrade actually changes what those alarms do at boot.
 * An explicit null means never discard. Collapsing the two either strands
 * legacy alarms on the old policy or silently discards an alarm the application
 * said must always ring.
 */
class AlarmSettingsTest {
    private val defaultMillis = AlarmSettings.DEFAULT_STALE_AFTER_MILLIS

    private fun settings(staleAfterMillis: Long? = defaultMillis) = AlarmSettings(
        id = 42,
        dateTime = Date(1_786_086_270_000),
        assetAudioPath = "assets/alarm.mp3",
        volumeSettings = VolumeSettings(
            volume = 0.8,
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
    fun `defaults to fifteen minutes`() {
        assertEquals(900_000L, defaultMillis)
        assertEquals(defaultMillis, settings().androidStaleAfterMillis)
    }

    @Test
    fun `an explicit null round trips as never discard`() {
        val json = Json.encodeToString(settings(staleAfterMillis = null))

        assertNull(Json.decodeFromString<AlarmSettings>(json).androidStaleAfterMillis)
    }

    @Test
    fun `a duration round trips`() {
        val json = Json.encodeToString(settings(staleAfterMillis = 2_400_000L))

        assertEquals(
            2_400_000L,
            Json.decodeFromString<AlarmSettings>(json).androidStaleAfterMillis,
        )
    }

    @Test
    fun `an alarm stored before the cutoff existed takes the default`() {
        // Json omits a property equal to its declared default, so an alarm using
        // the default is stored exactly like one written by 5.10.0: no key at
        // all. Both therefore have to read back as the default, not as null.
        val json = Json.encodeToString(settings())

        assertFalse(json.contains("androidStaleAfterMillis"))
        assertEquals(
            defaultMillis,
            Json.decodeFromString<AlarmSettings>(json).androidStaleAfterMillis,
        )
    }

    @Test
    fun `the legacy parser keeps the three states apart`() {
        val full = Json.encodeToString(settings(staleAfterMillis = 2_400_000L))

        assertEquals(
            2_400_000L,
            AlarmSettings.fromJson(full).androidStaleAfterMillis,
        )
        assertNull(
            AlarmSettings.fromJson(
                full.replace("\"androidStaleAfterMillis\":2400000", "\"androidStaleAfterMillis\":null")
            ).androidStaleAfterMillis,
        )
        assertEquals(
            defaultMillis,
            AlarmSettings.fromJson(
                full.replace(",\"androidStaleAfterMillis\":2400000", "")
            ).androidStaleAfterMillis,
        )
    }

    @Test
    fun `the legacy parser falls back to the default on an unusable value`() {
        // Recovering matches the Dart reader: the alarm itself is still good,
        // and refusing to parse it would lose the alarm over one bad field.
        val json = Json.encodeToString(settings(staleAfterMillis = 2_400_000L))
            .replace("\"androidStaleAfterMillis\":2400000", "\"androidStaleAfterMillis\":\"oops\"")

        assertEquals(defaultMillis, AlarmSettings.fromJson(json).androidStaleAfterMillis)
    }

    @Test
    fun `the legacy parser falls back rather than throwing on a non-primitive`() {
        // A string recovers through toLongOrNull, but an object or an array
        // reaches neither branch: `jsonPrimitive` throws on those, which would
        // cost the whole alarm rather than the one field.
        val full = Json.encodeToString(settings(staleAfterMillis = 2_400_000L))

        for (bad in listOf("{}", "[]", "{\"minutes\":15}")) {
            val json = full.replace("\"androidStaleAfterMillis\":2400000", "\"androidStaleAfterMillis\":$bad")

            assertEquals(
                "recovered from $bad",
                defaultMillis,
                AlarmSettings.fromJson(json).androidStaleAfterMillis,
            )
        }
    }
}
