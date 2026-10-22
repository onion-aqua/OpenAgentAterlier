package com.gdelataillade.alarm.services

import android.Manifest
import android.annotation.TargetApi
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.TelephonyManager

/** Process-local alarm policy, independent of Activity and Flutter lifecycle. */
object AlarmCallAudioPolicy {
    private const val POLL_MS = 300L
    private val handler = Handler(Looper.getMainLooper())
    private val listeners = linkedSetOf<() -> Unit>()
    private var appContext: Context? = null
    private var audioManager: AudioManager? = null
    private var telephonyManager: TelephonyManager? = null
    private var modeListener: AudioManager.OnModeChangedListener? = null
    private var focusRequest: AudioFocusRequest? = null
    private var legacyFocusListener: AudioManager.OnAudioFocusChangeListener? = null
    private var focusEpoch = 0L
    private var callActive = false
    private var focusGranted = false
    private var focusRegistered = false
    private var masterGain = 1f

    /** The app media guard yields its focus while native alarm players exist. */
    fun hasActivePlayers(): Boolean = listeners.isNotEmpty()

    val effectiveMasterGain: Float
        get() = if (callActive || !focusGranted) 0f else masterGain

    private val poll = object : Runnable {
        override fun run() {
            if (listeners.isEmpty()) return
            refreshCallState()
            handler.postDelayed(this, POLL_MS)
        }
    }

    fun setMasterGain(gain: Float) {
        masterGain = if (gain.isFinite()) gain.coerceIn(0f, 1f) else 0f
        notifyPlayers()
    }

    fun refreshBeforePlayback() {
        refreshCallState()
    }

    fun addPlayer(context: Context, listener: () -> Unit) {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (listeners.isEmpty()) {
            appContext = context.applicationContext
            audioManager = appContext?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            telephonyManager = appContext?.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) registerModeListener()
        }
        listeners.add(listener)
        refreshCallState()
        if (!callActive && !focusRegistered) requestFocus()
        listener()
        handler.removeCallbacks(poll)
        handler.postDelayed(poll, POLL_MS)
    }

    fun removePlayer(listener: () -> Unit) {
        listeners.remove(listener)
        if (listeners.isNotEmpty()) return
        handler.removeCallbacks(poll)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            modeListener?.let { runCatching { audioManager?.removeOnModeChangedListener(it) } }
        }
        modeListener = null
        abandonFocus()
        appContext = null
        audioManager = null
        telephonyManager = null
        callActive = false
    }

    @Suppress("DEPRECATION")
    private fun refreshCallState() {
        val manager = audioManager
        val context = appContext
        val mode = runCatching { manager?.mode }.getOrNull() ?: AudioManager.MODE_NORMAL
        val allowed = context != null && (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED)
        val phoneState = if (allowed) runCatching { telephonyManager?.callState }.getOrNull() else null
        val active = isCommunicationMode(mode) ||
            phoneState == TelephonyManager.CALL_STATE_RINGING || phoneState == TelephonyManager.CALL_STATE_OFFHOOK
        val previous = callActive
        callActive = active
        if (active) {
            // Publish zero before releasing focus; no release callback may
            // restore audio in the middle of a conversation.
            notifyPlayers()
            if (focusRegistered || focusGranted) abandonFocus()
        } else if (previous && listeners.isNotEmpty()) {
            requestFocus()
        }
        notifyPlayers()
    }

    internal fun isCommunicationMode(mode: Int): Boolean = when (mode) {
        AudioManager.MODE_RINGTONE, AudioManager.MODE_IN_CALL, AudioManager.MODE_IN_COMMUNICATION -> true
        else -> (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && mode == AudioManager.MODE_CALL_SCREENING) ||
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                (mode == AudioManager.MODE_CALL_REDIRECT || mode == AudioManager.MODE_COMMUNICATION_REDIRECT))
    }

    @TargetApi(Build.VERSION_CODES.S)
    private fun registerModeListener() {
        val context = appContext ?: return
        val callback = AudioManager.OnModeChangedListener {
            if (listeners.isNotEmpty()) refreshCallState()
        }
        if (runCatching { audioManager?.addOnModeChangedListener(context.mainExecutor, callback) }.isSuccess) {
            modeListener = callback
        }
    }

    @Suppress("DEPRECATION")
    private fun requestFocus() {
        if (callActive || listeners.isEmpty()) return
        val manager = audioManager ?: return
        abandonFocus()
        val epoch = ++focusEpoch
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            if (epoch != focusEpoch || listeners.isEmpty()) return@OnAudioFocusChangeListener
            focusGranted = change == AudioManager.AUDIOFOCUS_GAIN && !callActive
            notifyPlayers()
        }
        val result = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                    .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                    .setOnAudioFocusChangeListener(listener, handler)
                    .setWillPauseWhenDucked(true)
                    .setAcceptsDelayedFocusGain(true)
                    .build()
                focusRequest = request
                manager.requestAudioFocus(request)
            } else {
                legacyFocusListener = listener
                manager.requestAudioFocus(listener, AudioManager.STREAM_ALARM, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            }
        }.getOrNull()
        focusRegistered = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED ||
            result == AudioManager.AUDIOFOCUS_REQUEST_DELAYED
        focusGranted = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED && !callActive
        if (!focusRegistered) abandonFocus()
        notifyPlayers()
    }

    @Suppress("DEPRECATION")
    private fun abandonFocus() {
        ++focusEpoch
        focusGranted = false
        focusRegistered = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { runCatching { audioManager?.abandonAudioFocusRequest(it) } }
        } else {
            legacyFocusListener?.let { runCatching { audioManager?.abandonAudioFocus(it) } }
        }
        focusRequest = null
        legacyFocusListener = null
    }

    private fun notifyPlayers() {
        listeners.toList().forEach { runCatching { it() } }
    }
}
