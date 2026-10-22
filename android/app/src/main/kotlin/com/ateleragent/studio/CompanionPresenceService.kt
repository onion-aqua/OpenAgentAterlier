package com.ateleragent.studio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/** A user-visible companion session, never a silent playback or restart loop. */
class CompanionPresenceService : Service() {
    companion object {
        const val CHANNEL_ID = "character_companion_runtime"
        private const val NOTIFICATION_ID = 10418
        private const val ACTION_START = "com.ateleragent.studio.COMPANION_START"
        private const val ACTION_STOP = "com.ateleragent.studio.COMPANION_STOP"
        private var activeService: CompanionPresenceService? = null

        fun setCompanionName(context: Context, name: String): Map<String, Any> {
            CompanionRuntimeState.setCompanionName(name)
            activeService?.refreshVisibleNotification()
            return CompanionRuntimeState.snapshot(context)
        }

        fun startFromForeground(context: Context, restoreNotification: Boolean = false): Map<String, Any> {
            if (CompanionRuntimeState.isRunningOrStarting()) {
                if (restoreNotification && CompanionRuntimeState.snapshot(context)["running"] == true) {
                    // Repost only after an explicit action in app settings.
                    runCatching {
                        context.startService(Intent(context, CompanionPresenceService::class.java).setAction(ACTION_START))
                    }
                }
                return CompanionRuntimeState.snapshot(context)
            }
            CompanionRuntimeState.setStarting()
            try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, CompanionPresenceService::class.java).setAction(ACTION_START),
                )
            } catch (error: RuntimeException) {
                // Includes ROM restrictions and ForegroundServiceStartNotAllowedException.
                CompanionRuntimeState.startFailed(error.javaClass.simpleName)
                // The visible app can still protect its audio if the ROM denies FGS.
                CallAudioGuard.start(context.applicationContext)
            }
            return CompanionRuntimeState.snapshot(context)
        }

        fun stopByUser(context: Context) {
            CompanionRuntimeState.stopped(userRequested = true)
            CallAudioGuard.stop()
            context.stopService(Intent(context, CompanionPresenceService::class.java))
        }

        fun notificationsAllowed(context: Context): Boolean {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val manager = context.getSystemService(NotificationManager::class.java)
                if (manager.getNotificationChannel(CHANNEL_ID)?.importance == NotificationManager.IMPORTANCE_NONE) {
                    return false
                }
            }
            return true
        }
    }

    override fun onCreate() {
        super.onCreate()
        activeService = this
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "角色陪伴运行状态", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "显示应用的后台陪伴运行状态，可随时停止"
                    setSound(null, null)
                    enableVibration(false)
                    setShowBadge(false)
                    lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                },
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopByUser(this)
            return START_NOT_STICKY
        }
        // START_NOT_STICKY prevents Android from recreating a phantom companion.
        if (intent?.action != ACTION_START || CompanionRuntimeState.isStopRequested()) {
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            val notification = makeNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            CompanionRuntimeState.started()
            // Requesting focus before FGS is established can fail on Android 15+.
            CallAudioGuard.start(applicationContext)
            if (CallAudioGuard.snapshot()["audioActive"] == true) {
                CallAudioGuard.setAudioActive(true)
            }
        } catch (error: RuntimeException) {
            CompanionRuntimeState.startFailed(error.javaClass.simpleName)
            // Preserve foreground call protection even if the notification is denied.
            CallAudioGuard.start(applicationContext)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun makeNotification(): Notification {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val openApp = PendingIntent.getActivity(
            this,
            NOTIFICATION_ID,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            flags,
        )
        val stop = PendingIntent.getService(
            this,
            NOTIFICATION_ID + 1,
            Intent(this, CompanionPresenceService::class.java).setAction(ACTION_STOP),
            flags,
        )
        val publicVersion = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_companion_notification)
            .setContentTitle("AgentAtelier")
            .setContentText("角色陪伴正在运行")
            .setContentIntent(openApp)
            .setSilent(true)
            .build()
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_companion_notification)
            .setContentTitle("AgentAtelier")
            .setContentText(CompanionRuntimeState.companionMessage())
            .setContentIntent(openApp)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .addAction(0, "停止后台运行", stop)
            .build()
    }

    private fun refreshVisibleNotification() {
        if (!CompanionPresenceService.notificationsAllowed(this)) return
        if (CompanionRuntimeState.snapshot(this)["running"] != true) return
        // Updating a model must not restore a notification dismissed by the
        // user (possible for ongoing notifications on Android 14 and later).
        runCatching {
            val manager = getSystemService(NotificationManager::class.java)
            if (manager.activeNotifications.any { it.id == NOTIFICATION_ID }) {
                manager.notify(NOTIFICATION_ID, makeNotification())
            }
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopByUser(this)
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        if (activeService === this) activeService = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        CompanionRuntimeState.serviceDestroyed()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}

/** Session-only flags. Never persist a request to restart after process death. */
internal object CompanionRuntimeState {
    // Identity is intentionally session-only: after process death the service
    // starts with generic text until Flutter loads the selected model again.
    private var companionName = ""
    private var running = false
    private var starting = false
    private var stopRequested = false
    private var lastError = ""
    private var bridgeCount = 0
    private val listeners = linkedSetOf<() -> Unit>()

    fun snapshot(context: Context): Map<String, Any> = CallAudioGuard.snapshot() + mapOf(
        "running" to running,
        "starting" to starting,
        "stopRequested" to stopRequested,
        "notificationsAllowed" to CompanionPresenceService.notificationsAllowed(context),
        "manufacturer" to Build.MANUFACTURER,
        "lastError" to lastError,
    )

    fun addListener(listener: () -> Unit) { listeners.add(listener) }
    fun removeListener(listener: () -> Unit) { listeners.remove(listener) }
    fun isRunningOrStarting(): Boolean = running || starting
    fun isStopRequested(): Boolean = stopRequested
    fun setCompanionName(name: String) {
        companionName = name.replace(Regex("[\\p{Cc}]+"), " ").trim().take(60)
    }
    fun companionMessage(): String = if (companionName.isEmpty()) {
        "角色陪伴正在运行"
    } else {
        "${companionName}一直陪在你的身边哦"
    }
    fun attachBridge() { bridgeCount += 1 }
    fun detachBridge() {
        bridgeCount = (bridgeCount - 1).coerceAtLeast(0)
        if (bridgeCount == 0 && !running && !starting) CallAudioGuard.stop()
    }

    fun setStarting() {
        starting = !running
        stopRequested = false
        lastError = ""
        publish()
    }

    fun started() {
        running = true
        starting = false
        stopRequested = false
        lastError = ""
        publish()
    }

    fun startFailed(error: String) {
        running = false
        starting = false
        lastError = error
        publish()
    }

    fun stopped(userRequested: Boolean) {
        running = false
        starting = false
        stopRequested = userRequested
        publish()
    }

    fun serviceDestroyed() {
        running = false
        starting = false
        // A rejected FGS must not remove call protection from a still visible
        // Flutter app. With no UI/FGS owner left, release every native callback.
        if (stopRequested || bridgeCount == 0) CallAudioGuard.stop()
        publish()
    }

    private fun publish() { listeners.toList().forEach { it() } }
}
