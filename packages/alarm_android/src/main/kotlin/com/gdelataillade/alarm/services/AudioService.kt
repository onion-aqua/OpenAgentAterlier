package com.gdelataillade.alarm.services

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.gdelataillade.alarm.models.VolumeFadeStep
import io.flutter.Log
import kotlin.time.Duration

/** Native alarm players use the same call-safe gain policy without Flutter. */
class AudioService(private val context: Context) {
    companion object {
        private const val TAG = "AudioService"
        private const val FADE_INTERVAL_MS = 100L
    }

    private data class Playback(
        val player: MediaPlayer,
        val startedAt: Long,
        val envelope: AlarmPlaybackEnvelope,
    )

    private val handler = Handler(Looper.getMainLooper())
    private val mediaPlayers = linkedMapOf<Int, Playback>()
    private val onAudioCompleteListeners = mutableMapOf<Int, () -> Unit>()
    private var registeredWithPolicy = false
    private val onPolicyChanged: () -> Unit = { applyCurrentGains() }
    private val fadeTick = object : Runnable {
        override fun run() {
            if (mediaPlayers.isEmpty()) return
            applyCurrentGains()
            handler.postDelayed(this, FADE_INTERVAL_MS)
        }
    }

    fun setOnAudioCompleteListener(id: Int, listener: () -> Unit) {
        onAudioCompleteListeners[id] = listener
    }

    fun getPlayingMediaPlayersIds(): List<Int> = mediaPlayers.filter { (_, playback) ->
        runCatching { playback.player.isPlaying }.getOrDefault(false)
    }.keys.toList()

    fun playAudio(
        id: Int,
        filePath: String?,
        loopAudio: Boolean,
        fadeDuration: Duration?,
        fadeSteps: List<VolumeFadeStep>,
        preferConnectedAudioDevice: Boolean,
    ) {
        releaseMediaPlayer(id)
        val mediaPlayer = MediaPlayer()
        try {
            if (filePath == null) {
                val defaultUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                    ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                    ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                    ?: throw IllegalStateException("No default alarm sound available")
                mediaPlayer.setDataSource(context, defaultUri)
            } else {
                val sourcePath = requireNotNull(filePath)
                val adjusted = when {
                    sourcePath.startsWith("assets/") -> "flutter_assets/$sourcePath"
                    !sourcePath.startsWith("/") -> context.filesDir.parent + "/app_flutter/" + sourcePath
                    else -> sourcePath
                }
                if (adjusted.startsWith("flutter_assets/")) {
                    context.assets.openFd(adjusted).use { descriptor ->
                        mediaPlayer.setDataSource(descriptor.fileDescriptor, descriptor.startOffset, descriptor.length)
                    }
                } else {
                    mediaPlayer.setDataSource(adjusted)
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                mediaPlayer.setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(if (preferConnectedAudioDevice) AudioAttributes.USAGE_MEDIA else AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
            } else {
                @Suppress("DEPRECATION")
                mediaPlayer.setAudioStreamType(if (preferConnectedAudioDevice) AudioManager.STREAM_MUSIC else AudioManager.STREAM_ALARM)
            }
            mediaPlayer.prepare()
            mediaPlayer.isLooping = loopAudio
            // Never emit the default full-volume frame while mode/focus is
            // being checked, including alarms that cold-start this process.
            mediaPlayer.setVolume(0f, 0f)
            mediaPlayers[id] = Playback(
                mediaPlayer,
                SystemClock.elapsedRealtime(),
                AlarmPlaybackEnvelope(fadeDuration?.inWholeMilliseconds,
                    fadeSteps.map { it.time.inWholeMilliseconds to it.volume.toFloat() }),
            )
            mediaPlayer.setOnCompletionListener {
                if (!loopAudio && mediaPlayers[id]?.player === mediaPlayer) {
                    val completion = onAudioCompleteListeners[id]
                    releaseMediaPlayer(id)
                    completion?.invoke()
                }
            }
            if (!registeredWithPolicy) {
                registeredWithPolicy = true
                AlarmCallAudioPolicy.addPlayer(context, onPolicyChanged)
            } else {
                // An overlapping/new alarm also takes a fresh call snapshot;
                // it must not reuse a pre-call gain until the next poll.
                AlarmCallAudioPolicy.refreshBeforePlayback()
            }
            mediaPlayer.start()
            applyCurrentGains()
            handler.removeCallbacks(fadeTick)
            handler.postDelayed(fadeTick, FADE_INTERVAL_MS)
        } catch (error: Exception) {
            mediaPlayers.remove(id)
            runCatching { mediaPlayer.release() }
            stopPolicyIfIdle()
            Log.e(TAG, "Error playing audio for alarm $id", error)
        }
    }

    fun stopAudio(id: Int) {
        onAudioCompleteListeners.remove(id)
        releaseMediaPlayer(id)
    }

    private fun applyCurrentGains() {
        val now = SystemClock.elapsedRealtime()
        val masterGain = AlarmCallAudioPolicy.effectiveMasterGain
        for (playback in mediaPlayers.values) {
            val gain = playback.envelope.gainAt(now - playback.startedAt, masterGain)
            runCatching { playback.player.setVolume(gain, gain) }
        }
    }

    private fun releaseMediaPlayer(id: Int) {
        mediaPlayers.remove(id)?.player?.let { player ->
            runCatching { player.setOnCompletionListener(null) }
            runCatching { player.stop() }
            runCatching { player.reset() }
            runCatching { player.release() }
        }
        stopPolicyIfIdle()
    }

    private fun stopPolicyIfIdle() {
        if (mediaPlayers.isNotEmpty()) return
        handler.removeCallbacks(fadeTick)
        if (registeredWithPolicy) {
            registeredWithPolicy = false
            AlarmCallAudioPolicy.removePlayer(onPolicyChanged)
        }
    }

    fun cleanUp() {
        onAudioCompleteListeners.clear()
        mediaPlayers.keys.toList().forEach(::releaseMediaPlayer)
        stopPolicyIfIdle()
    }
}
