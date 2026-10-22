package com.ateleragent.studio

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Native companion lifecycle and call audio signals, separate from alarm/push. */
class CompanionRuntimeBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(messenger, "agent_atelier_r/companion_runtime")
    private val events = EventChannel(messenger, "agent_atelier_r/companion_runtime/events")
    private var sink: EventChannel.EventSink? = null
    private var disposed = false
    private val guardListener: (Map<String, Any>) -> Unit = { emitState() }
    private val runtimeListener: () -> Unit = { emitState() }

    init {
        CompanionRuntimeState.attachBridge()
        CallAudioGuard.addListener(guardListener)
        CompanionRuntimeState.addListener(runtimeListener)
        events.setStreamHandler(this)
        methods.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> result.success(CompanionPresenceService.startFromForeground(activity, restoreNotification = true))
                "setCompanionName" -> result.success(
                    CompanionPresenceService.setCompanionName(activity, call.argument<String>("name") ?: ""),
                )
                "setAudioActive" -> {
                    CallAudioGuard.setAudioActive(call.argument<Boolean>("active") ?: false)
                    result.success(snapshot())
                }
                "getState" -> {
                    // A permission grant may have occurred while Settings was open.
                    if (!CompanionRuntimeState.isStopRequested()) {
                        CallAudioGuard.start(activity.applicationContext)
                    }
                    result.success(snapshot())
                }
                "stop" -> {
                    CompanionPresenceService.stopByUser(activity)
                    result.success(snapshot())
                }
                "openBackgroundSettings" -> result.success(openBackgroundSettings())
                else -> result.notImplemented()
            }
        }
    }

    fun startFromForeground(): Map<String, Any> =
        CompanionPresenceService.startFromForeground(activity)

    fun startInitially() {
        if (!CompanionRuntimeState.isStopRequested()) startFromForeground()
    }

    fun refresh() { emitState() }

    private fun snapshot(): Map<String, Any> = CompanionRuntimeState.snapshot(activity)

    private fun emitState() {
        mainHandler.post { if (!disposed) sink?.success(snapshot()) }
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        sink = eventSink
        emitState()
    }

    override fun onCancel(arguments: Any?) { sink = null }

    fun dispose() {
        disposed = true
        sink = null
        CallAudioGuard.removeListener(guardListener)
        CompanionRuntimeState.removeListener(runtimeListener)
        CompanionRuntimeState.detachBridge()
        events.setStreamHandler(null)
        methods.setMethodCallHandler(null)
        // An Activity can be destroyed while the actual companion FGS is alive.
    }

    private fun openBackgroundSettings(): Map<String, Any> {
        val manufacturer = Build.MANUFACTURER.lowercase()
        val vendorComponents = when {
            manufacturer.contains("xiaomi") || manufacturer.contains("redmi") || manufacturer.contains("poco") -> listOf(
                ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
            )
            manufacturer.contains("huawei") || manufacturer.contains("honor") -> listOf(
                ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
                ComponentName("com.hihonor.systemmanager", "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            )
            manufacturer.contains("oppo") || manufacturer.contains("realme") || manufacturer.contains("oneplus") -> listOf(
                ComponentName("com.oplus.safecenter", "com.oplus.safecenter.startupapp.StartupAppListActivity"),
                ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
                ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
            )
            manufacturer.contains("vivo") || manufacturer.contains("iqoo") -> listOf(
                ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
                ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
            )
            manufacturer.contains("samsung") -> listOf(
                ComponentName("com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity"),
            )
            manufacturer.contains("asus") -> listOf(
                ComponentName("com.asus.mobilemanager", "com.asus.mobilemanager.powersaver.PowerSaverSettings"),
            )
            else -> emptyList()
        }
        // Activities vary by ROM version: try explicit user-requested destinations,
        // then use supported Android settings. Never add a whitelist silently.
        for (component in vendorComponents) {
            if (tryOpen(Intent().setComponent(component).putExtra("package_name", activity.packageName))) {
                return mapOf("opened" to true, "destination" to "vendor_background_settings")
            }
        }
        if (manufacturer.contains("meizu") && tryOpen(
                Intent("com.meizu.safe.security.SHOW_APPSEC")
                    .setPackage("com.meizu.safe")
                    .putExtra("packageName", activity.packageName),
            )) {
            return mapOf("opened" to true, "destination" to "vendor_background_settings")
        }
        if (tryOpen(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}")))) {
            return mapOf("opened" to true, "destination" to "application_settings")
        }
        if (tryOpen(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))) {
            return mapOf("opened" to true, "destination" to "battery_optimization_settings")
        }
        return mapOf("opened" to false, "destination" to "unavailable")
    }

    private fun tryOpen(intent: Intent): Boolean = try {
        activity.startActivity(intent)
        true
    } catch (_: RuntimeException) {
        false
    }
}
