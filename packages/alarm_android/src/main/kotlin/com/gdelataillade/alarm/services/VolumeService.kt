package com.gdelataillade.alarm.services

import android.content.Context

/** Keep the upstream service API without changing any system audio stream. */
@Suppress("UNUSED_PARAMETER")
class VolumeService(context: Context) {
    fun setVolume(
        volume: Double,
        volumeEnforced: Boolean,
        showSystemUI: Boolean,
        preferConnectedAudioDevice: Boolean,
    ) {
        AlarmCallAudioPolicy.setMasterGain(volume.toFloat())
    }

    fun restorePreviousVolume(showSystemUI: Boolean) {
        AlarmCallAudioPolicy.setMasterGain(1f)
    }

    // AudioService owns focus while actual players exist. Merely scheduling or
    // preparing an alarm must never take focus away from communication audio.
    fun requestAudioFocus(preferConnectedAudioDevice: Boolean) = Unit
    fun abandonAudioFocus() = Unit
}
