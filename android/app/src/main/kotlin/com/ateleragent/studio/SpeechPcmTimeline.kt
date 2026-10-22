package com.ateleragent.studio

/** Timeline of decoded PCM frames; container timestamps never alter duration. */
internal class SpeechPcmTimeline {
    var sampleRate: Int = 0
        private set
    var channels: Int = 0
        private set
    var sampleFrames: Long = 0L
        private set

    val durationUs: Long
        get() = if (sampleRate > 0) sampleFrames * 1_000_000L / sampleRate else 0L

    fun setFormat(rate: Int, channelCount: Int) {
        require(rate in 8_000..192_000 && channelCount in 1..8) { "Unsupported decoded audio format" }
        check(sampleFrames == 0L || (rate == sampleRate && channelCount == channels)) {
            "Decoded audio format changed mid-stream"
        }
        sampleRate = rate
        channels = channelCount
    }

    /** Called once for each complete interleaved frame, not per channel. */
    fun nextWindow(): Int {
        check(sampleRate > 0 && channels > 0) { "Missing decoded audio format" }
        check(sampleFrames < sampleRate * 600L) { "Audio exceeds ten minutes" }
        check((sampleFrames + 1L) * channels * 2L <= 64L * 1024 * 1024) { "Decoded audio too large" }
        val window = (sampleFrames * 1_000_000L / sampleRate / 20_000L).toInt()
        ++sampleFrames
        return window
    }
}
