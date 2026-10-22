package com.ateleragent.studio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class SpeechPcmTimelineTest {
    @Test
    fun nineteenSecondsDoesNotBecomeSeventyOneFromContainerOffset() {
        val timeline = SpeechPcmTimeline().apply { setFormat(24_000, 2) }
        // Container PTS could start at 52_000_000us; it is deliberately absent
        // from the PCM API. Both continuous and split decoder buffers use this.
        repeat(24_000 * 7) { timeline.nextWindow() }
        timeline.setFormat(24_000, 2)
        repeat(24_000 * 12) { timeline.nextWindow() }
        assertEquals(19_000_000L, timeline.durationUs)
        assertEquals(456_000L, timeline.sampleFrames)
    }

    @Test
    fun actualSeventyOneSecondsStaysSeventyOne() {
        val timeline = SpeechPcmTimeline().apply { setFormat(16_000, 1) }
        var last = -1
        repeat(16_000 * 71) { last = timeline.nextWindow() }
        assertEquals(71_000_000L, timeline.durationUs)
        assertEquals(3549, last)
    }

    @Test
    fun partialWindowHasExactFrameDurationForAnyChannelCount() {
        for (channels in listOf(1, 2, 6)) {
            val timeline = SpeechPcmTimeline().apply { setFormat(44_100, channels) }
            repeat(44_100 * 2 + 117) { timeline.nextWindow() }
            assertEquals(2_002_653L, timeline.durationUs)
        }
    }

    @Test
    fun decoderMayCorrectHeaderFormatBeforeFramesButCannotChangeItDuringAudio() {
        val timeline = SpeechPcmTimeline().apply {
            setFormat(24_000, 1)
            setFormat(48_000, 2)
            nextWindow()
        }
        assertThrows(IllegalStateException::class.java) { timeline.setFormat(24_000, 2) }
        assertThrows(IllegalStateException::class.java) { timeline.setFormat(48_000, 1) }
        assertThrows(IllegalArgumentException::class.java) { SpeechPcmTimeline().setFormat(0, 1) }
    }

    @Test
    fun tenMinuteLimitRejectsAnotherFrame() {
        val timeline = SpeechPcmTimeline().apply { setFormat(8_000, 1) }
        repeat(8_000 * 600) { timeline.nextWindow() }
        assertEquals(600_000_000L, timeline.durationUs)
        assertThrows(IllegalStateException::class.java) { timeline.nextWindow() }
    }
}
