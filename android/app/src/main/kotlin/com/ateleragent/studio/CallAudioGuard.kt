package com.ateleragent.studio

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
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import com.gdelataillade.alarm.services.AlarmCallAudioPolicy

/**
 * Watches the system communication mode as well as media audio focus. No attempt
 * is made to inspect another app, change its volume, or take communication focus.
 * All mutations and listener callbacks run on the main thread.
 */
object CallAudioGuard {
    private const val POLL_INTERVAL_MS = 1000L
    private val mainHandler = Handler(Looper.getMainLooper())
    private val listeners = linkedSetOf<(Map<String, Any>) -> Unit>()
    private var applicationContext: Context? = null
    private var audioManager: AudioManager? = null
    private var telephonyManager: TelephonyManager? = null
    private var monitoring = false
    private var mediaActive = false
    private var audioMode = AudioManager.MODE_NORMAL
    private var phoneState = TelephonyManager.CALL_STATE_IDLE
    private var phonePermission = false
    private var phoneCallback: TelephonyCallback? = null
    private var legacyPhoneListener: PhoneStateListener? = null
    private var phoneEpoch = 0L
    private var modeListener: AudioManager.OnModeChangedListener? = null
    private var focusRequest: AudioFocusRequest? = null
    private var legacyFocusListener: AudioManager.OnAudioFocusChangeListener? = null
    private var focusRegistered = false
    private var focusGranted = false
    private var focusEpoch = 0L
    private var focusReason = "idle"
    private var previousCallActive = false
    private var previousAlarmActive = false

    @Volatile
    private var published: Map<String, Any> = mapOf(
        "muted" to false,
        "callActive" to false,
        "alarmActive" to false,
        "focusLost" to false,
        "monitoring" to false,
        "audioActive" to false,
        "audioMode" to AudioManager.MODE_NORMAL,
        "phoneStatePermission" to false,
        "reason" to "idle",
    )

    private val poll = object : Runnable {
        override fun run() {
            if (!monitoring) return
            // Some ROMs and VoIP apps omit the mode callback or use an older API.
            refreshPhoneRegistration()
            refreshSystemState()
            mainHandler.postDelayed(this, POLL_INTERVAL_MS)
        }
    }

    fun start(context: Context) = onMain {
        if (!monitoring) {
            applicationContext = context.applicationContext
            audioManager = applicationContext?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            telephonyManager = applicationContext?.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            monitoring = true
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) registerModeListener()
            refreshPhoneRegistration()
            refreshSystemState()
            mainHandler.removeCallbacks(poll)
            mainHandler.postDelayed(poll, POLL_INTERVAL_MS)
        } else {
            // A resume or a new permission grant also refreshes an existing guard.
            refreshPhoneRegistration()
            refreshSystemState()
        }
        // A generic state refresh must not take focus back from another app.
        // The service may re-announce active playback once its FGS is ready.
        if (mediaActive && !isCallActive() && !isAlarmActive() && !focusRegistered && focusReason == "idle") {
            requestMediaFocus()
        }
        publish()
    }

    fun stop() = onMain {
        monitoring = false
        mainHandler.removeCallbacks(poll)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) unregisterModeListener()
        unregisterPhoneListener()
        abandonMediaFocus()
        mediaActive = false
        previousCallActive = false
        previousAlarmActive = false
        audioMode = AudioManager.MODE_NORMAL
        phoneState = TelephonyManager.CALL_STATE_IDLE
        phonePermission = false
        focusReason = "idle"
        applicationContext = null
        audioManager = null
        telephonyManager = null
        publish()
    }

    fun snapshot(): Map<String, Any> = HashMap(published)

    fun setAudioActive(active: Boolean) = onMain {
        if (active && monitoring) refreshSystemState()
        if (mediaActive == active) {
            // A new explicit playback attempt can recover a denied/permanently
            // lost request. Transient loss and duck keep their registration and
            // wait for GAIN rather than stealing focus from the current owner.
            if (active && monitoring && !isCallActive() && !isAlarmActive() && !focusRegistered) {
                requestMediaFocus()
                publish()
            }
            return@onMain
        }
        mediaActive = active
        if (!active) {
            abandonMediaFocus()
            focusReason = "idle"
        } else if (monitoring) {
            refreshSystemState()
            if (!isCallActive() && !isAlarmActive() && !focusRegistered) requestMediaFocus()
        }
        publish()
    }

    fun addListener(listener: (Map<String, Any>) -> Unit) = onMain {
        listeners.add(listener)
        runCatching { listener(snapshot()) }
    }

    fun removeListener(listener: (Map<String, Any>) -> Unit) = onMain {
        listeners.remove(listener)
    }

    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) action() else mainHandler.post { action() }
    }

    private fun isCommunicationMode(mode: Int): Boolean = when (mode) {
        AudioManager.MODE_RINGTONE,
        AudioManager.MODE_IN_CALL,
        AudioManager.MODE_IN_COMMUNICATION -> true
        else -> (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && mode == AudioManager.MODE_CALL_SCREENING) ||
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                (mode == AudioManager.MODE_CALL_REDIRECT || mode == AudioManager.MODE_COMMUNICATION_REDIRECT))
    }

    private fun isCallActive(): Boolean = monitoring && (
        isCommunicationMode(audioMode) || phoneState == TelephonyManager.CALL_STATE_RINGING ||
            phoneState == TelephonyManager.CALL_STATE_OFFHOOK
        )

    private fun isAlarmActive(): Boolean = AlarmCallAudioPolicy.hasActivePlayers()

    @Suppress("DEPRECATION")
    private fun refreshSystemState() {
        if (!monitoring) return
        audioMode = runCatching { audioManager?.mode }.getOrNull() ?: audioMode
        if (phonePermission) {
            // Supplement the callback with a snapshot for restored processes and
            // ROMs that fail to dispatch their initial phone-state callback.
            runCatching { telephonyManager?.callState }.getOrNull()?.let { phoneState = it }
        }
        reconcileCallState()
    }

    private fun reconcileCallState() {
        val callActive = isCallActive()
        val alarmActive = isAlarmActive()
        if (callActive) {
            if (focusRegistered || focusGranted) abandonMediaFocus()
            focusReason = "call"
        } else if (alarmActive) {
            // Native alarms own transient focus. Taking media GAIN after a
            // call would permanently evict the alarm's request from the stack.
            if (focusRegistered || focusGranted) abandonMediaFocus()
            focusReason = "alarm"
        } else if (previousCallActive || previousAlarmActive) {
            // Keep muted through the transition. A normal-mode callback alone
            // must not resume audio before Android grants media focus again.
            if (mediaActive) requestMediaFocus() else focusReason = "idle"
        }
        previousCallActive = callActive
        previousAlarmActive = alarmActive
        publish()
    }

    @TargetApi(Build.VERSION_CODES.S)
    private fun registerModeListener() {
        val manager = audioManager ?: return
        val listener = AudioManager.OnModeChangedListener {
            onMain { if (monitoring) refreshSystemState() }
        }
        if (runCatching { manager.addOnModeChangedListener(applicationContext!!.mainExecutor, listener) }.isSuccess) {
            modeListener = listener
        }
    }

    @TargetApi(Build.VERSION_CODES.S)
    private fun unregisterModeListener() {
        modeListener?.let { listener -> runCatching { audioManager?.removeOnModeChangedListener(listener) } }
        modeListener = null
    }

    private fun refreshPhoneRegistration() {
        val context = applicationContext ?: return
        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED
        val registered = phoneCallback != null || legacyPhoneListener != null
        if (!allowed || telephonyManager == null) {
            if (registered) unregisterPhoneListener()
            phonePermission = false
            phoneState = TelephonyManager.CALL_STATE_IDLE
            return
        }
        phonePermission = true
        if (registered) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) registerPhoneCallback() else registerLegacyPhoneListener()
    }

    @TargetApi(Build.VERSION_CODES.S)
    private fun registerPhoneCallback() {
        val manager = telephonyManager ?: return
        val epoch = ++phoneEpoch
        val callback = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
            override fun onCallStateChanged(state: Int) {
                onMain {
                    if (monitoring && phonePermission && epoch == phoneEpoch) {
                        phoneState = state
                        audioMode = runCatching { audioManager?.mode }.getOrNull() ?: audioMode
                        reconcileCallState()
                    }
                }
            }
        }
        if (runCatching { manager.registerTelephonyCallback(applicationContext!!.mainExecutor, callback) }.isSuccess) {
            phoneCallback = callback
        }
    }

    @Suppress("DEPRECATION")
    private fun registerLegacyPhoneListener() {
        val manager = telephonyManager ?: return
        val epoch = ++phoneEpoch
        val listener = object : PhoneStateListener() {
            override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                if (monitoring && phonePermission && epoch == phoneEpoch) {
                    phoneState = state
                    audioMode = runCatching { audioManager?.mode }.getOrNull() ?: audioMode
                    reconcileCallState()
                }
            }
        }
        if (runCatching { manager.listen(listener, PhoneStateListener.LISTEN_CALL_STATE) }.isSuccess) {
            legacyPhoneListener = listener
        }
    }

    @Suppress("DEPRECATION")
    private fun unregisterPhoneListener() {
        ++phoneEpoch
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            phoneCallback?.let { callback -> runCatching { telephonyManager?.unregisterTelephonyCallback(callback) } }
        }
        legacyPhoneListener?.let { listener ->
            runCatching { telephonyManager?.listen(listener, PhoneStateListener.LISTEN_NONE) }
        }
        phoneCallback = null
        legacyPhoneListener = null
    }

    @Suppress("DEPRECATION")
    private fun requestMediaFocus() {
        if (!monitoring || !mediaActive || isCallActive() || isAlarmActive() || focusRegistered) return
        val manager = audioManager
        if (manager == null) {
            focusGranted = false
            focusReason = "focus_unavailable"
            return
        }
        val epoch = ++focusEpoch
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            onMain {
                if (!monitoring || !mediaActive || epoch != focusEpoch) return@onMain
                audioMode = runCatching { audioManager?.mode }.getOrNull() ?: audioMode
                if (isCallActive() || isAlarmActive()) {
                    reconcileCallState()
                    return@onMain
                }
                if (change == AudioManager.AUDIOFOCUS_LOSS) {
                    abandonMediaFocus()
                } else {
                    focusGranted = change == AudioManager.AUDIOFOCUS_GAIN
                }
                focusReason = when (change) {
                    AudioManager.AUDIOFOCUS_GAIN -> "focus_granted"
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> "focus_duck"
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> "focus_transient_loss"
                    else -> "focus_loss"
                }
                publish()
            }
        }
        focusGranted = false
        focusRegistered = true
        focusReason = "focus_pending"
        val result = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build(),
                    )
                    .setAcceptsDelayedFocusGain(true)
                    .setWillPauseWhenDucked(true)
                    .setOnAudioFocusChangeListener(listener, mainHandler)
                    .build()
                focusRequest = request
                manager.requestAudioFocus(request)
            } else {
                legacyFocusListener = listener
                manager.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
            }
        }.getOrDefault(AudioManager.AUDIOFOCUS_REQUEST_FAILED)
        when (result) {
            AudioManager.AUDIOFOCUS_REQUEST_GRANTED -> {
                focusGranted = true
                focusReason = "focus_granted"
            }
            AudioManager.AUDIOFOCUS_REQUEST_DELAYED -> focusReason = "focus_delayed"
            else -> {
                abandonMediaFocus()
                focusReason = "focus_denied"
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun abandonMediaFocus() {
        ++focusEpoch // Ignore queued GAIN callbacks from an abandoned request.
        focusGranted = false
        focusRegistered = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { request -> runCatching { audioManager?.abandonAudioFocusRequest(request) } }
        }
        legacyFocusListener?.let { listener -> runCatching { audioManager?.abandonAudioFocus(listener) } }
        focusRequest = null
        legacyFocusListener = null
    }

    private fun publish() {
        val callActive = isCallActive()
        val alarmActive = isAlarmActive()
        // A foreground service starts asynchronously. A player can announce its
        // intent before start() runs; keep it silent until focus is granted.
        val focusLost = mediaActive && !focusGranted
        val next = mapOf<String, Any>(
            "muted" to (callActive || alarmActive || focusLost),
            "callActive" to callActive,
            "alarmActive" to alarmActive,
            "focusLost" to focusLost,
            "monitoring" to monitoring,
            "audioActive" to mediaActive,
            "audioMode" to audioMode,
            "phoneStatePermission" to phonePermission,
            "reason" to if (callActive) "call" else if (alarmActive) "alarm" else focusReason,
        )
        if (next == published) return
        published = next
        listeners.toList().forEach { listener -> runCatching { listener(HashMap(next)) } }
    }
}
