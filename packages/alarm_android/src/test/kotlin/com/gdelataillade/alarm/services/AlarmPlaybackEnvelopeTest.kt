package com.gdelataillade.alarm.services

import org.junit.Assert.assertEquals
import org.junit.Test

class AlarmPlaybackEnvelopeTest {
    @Test
    fun callMuteKeepsGainZeroAndRestoresCurrentFadePosition() {
        val fade = AlarmPlaybackEnvelope(4_000L, emptyList())
        assertEquals(0.25f, fade.gainAt(1_000L, 1f), 0.0001f)
        assertEquals(0f, fade.gainAt(2_000L, 0f), 0.0001f)
        // The fade continued during the call; it must not restart at 25%.
        assertEquals(0.75f, fade.gainAt(3_000L, 1f), 0.0001f)
        assertEquals(1f, fade.gainAt(8_000L, 1f), 0.0001f)
    }

    @Test
    fun latestUserVolumeIsAppliedAfterMuting() {
        val fade = AlarmPlaybackEnvelope(1_000L, emptyList())
        assertEquals(0.8f, fade.gainAt(2_000L, 0.8f), 0.0001f)
        assertEquals(0f, fade.gainAt(3_000L, 0f), 0.0001f)
        assertEquals(0.3f, fade.gainAt(4_000L, 0.3f), 0.0001f)
    }

    @Test
    fun staircaseEnvelopeRetainsLastLevelAndInterpolates() {
        val fade = AlarmPlaybackEnvelope(null,
            listOf(0L to 0.2f, 1_000L to 0.6f, 2_000L to 1f))
        assertEquals(0.2f, fade.gainAt(0L, 1f), 0.0001f)
        assertEquals(0.4f, fade.gainAt(500L, 1f), 0.0001f)
        assertEquals(0f, fade.gainAt(1_500L, 0f), 0.0001f)
        assertEquals(0.5f, fade.gainAt(8_000L, 0.5f), 0.0001f)
    }

    @Test
    fun noFadeAndInvalidGainsAreSafe() {
        val noFade = AlarmPlaybackEnvelope(null, emptyList())
        assertEquals(1f, noFade.gainAt(0L, 1f), 0f)
        assertEquals(0f, noFade.gainAt(0L, Float.NaN), 0f)
        assertEquals(1f, noFade.gainAt(0L, 3f), 0f)
        assertEquals(0f, noFade.gainAt(0L, -1f), 0f)
    }
}
