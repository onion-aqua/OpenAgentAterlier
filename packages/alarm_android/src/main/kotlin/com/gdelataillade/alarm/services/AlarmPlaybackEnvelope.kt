package com.gdelataillade.alarm.services

/** Desired gain uses elapsed time, so muting never restarts a fade-in. */
internal class AlarmPlaybackEnvelope(
    private val durationMillis: Long?,
    fadeSteps: List<Pair<Long, Float>>,
) {
    private val steps = fadeSteps.sortedBy { it.first }

    fun gainAt(elapsedMillis: Long, effectiveMasterGain: Float): Float {
        val elapsed = elapsedMillis.coerceAtLeast(0L)
        val desired = if (steps.isEmpty()) {
            val duration = durationMillis ?: 0L
            if (duration > 0L) (elapsed.toDouble() / duration).coerceIn(0.0, 1.0).toFloat() else 1f
        } else {
            val next = steps.indexOfFirst { it.first >= elapsed }
            when {
                next < 0 -> steps.last().second
                next == 0 -> steps.first().second
                else -> {
                    val previous = steps[next - 1]
                    val following = steps[next]
                    val width = following.first - previous.first
                    val fraction = if (width <= 0L) 1f else
                        ((elapsed - previous.first).toDouble() / width).toFloat()
                    previous.second + (following.second - previous.second) * fraction
                }
            }
        }
        val safeDesired = if (desired.isFinite()) desired.coerceIn(0f, 1f) else 0f
        val safeMaster = if (effectiveMasterGain.isFinite()) effectiveMasterGain.coerceIn(0f, 1f) else 0f
        return safeDesired * safeMaster
    }
}
