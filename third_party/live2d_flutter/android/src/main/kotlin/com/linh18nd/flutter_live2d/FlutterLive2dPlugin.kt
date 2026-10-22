package com.linh18nd.flutter_live2d

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class FlutterLive2dPlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context
    private val mainHandler = Handler(Looper.getMainLooper())

    // View registry: Flutter assigns each PlatformView an integer id.
    // We keep the mapping here so MethodChannel calls can find the right view.
    private val viewRegistry = mutableMapOf<Int, Live2DPlatformView>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "flutter_live2d")
        channel.setMethodCallHandler(this)

        binding.platformViewRegistry.registerViewFactory(
            "live2d_view",
            Live2DViewFactory(
                onCreated = { viewId, view -> viewRegistry[viewId] = view },
                onDisposed = { viewId -> viewRegistry.remove(viewId) }
            )
        )
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {

            "getPlatformVersion" ->
                result.success("Android ${android.os.Build.VERSION.RELEASE}")

            "getTempDirectory" ->
                result.success(appContext.cacheDir.absolutePath)

            "loadModel" -> {
                val viewId = call.requireInt("viewId", result) ?: return
                val modelDir = call.requireNonEmptyString("modelDir", result) ?: return
                val modelFileName = call.requireNonEmptyString("modelFileName", result) ?: return
                val view = viewRegistry[viewId] ?: run {
                    result.viewNotFound(viewId); return
                }
                view.loadModel(modelDir, modelFileName, commandError(result)) { ok ->
                    mainHandler.post { result.success(ok) }
                }
            }

            "unloadModel" -> {
                val viewId = call.requireInt("viewId", result) ?: return
                val view = viewRegistry[viewId] ?: run {
                    result.viewNotFound(viewId); return
                }
                view.unloadModel(commandError(result)) { mainHandler.post { result.success(null) } }
            }

            "setRenderingPaused" -> {
                val viewId = call.requireInt("viewId", result) ?: return
                val paused = call.argument<Boolean>("paused")
                if (paused == null) {
                    result.error("INVALID_ARGS", "Missing 'paused'", null); return
                }
                val view = viewRegistry[viewId] ?: run {
                    result.viewNotFound(viewId); return
                }
                view.setRenderingPaused(paused, commandError(result)) {
                    mainHandler.post { result.success(null) }
                }
            }

            "startMotion" -> {
                val viewId = call.requireInt("viewId", result) ?: return
                val group = call.requireString("group", result) ?: return
                val index = call.requireInt("index", result) ?: return
                val priority = call.argument<Int>("priority") ?: 2
                val view = viewRegistry[viewId] ?: run {
                    result.viewNotFound(viewId); return
                }
                view.startMotion(group, index, priority, commandError(result)) {
                    mainHandler.post { result.success(null) }
                }
            }

            "setIdleMotion" -> {
                val viewId = call.requireInt("viewId", result) ?: return
                val group = call.requireString("group", result) ?: return
                val index = call.requireInt("index", result) ?: return
                if (index < 0) {
                    result.error("INVALID_MOTION", "Idle motion index must be non-negative.", null)
                    return
                }
                val view = viewRegistry[viewId] ?: run {
                    result.viewNotFound(viewId); return
                }
                view.setIdleMotion(group, index, commandError(result)) {
                    mainHandler.post { result.success(null) }
                }
            }

            "setExpression" -> {
                val viewId = call.requireInt("viewId", result) ?: return
                val index = call.requireInt("index", result) ?: return
                val view = viewRegistry[viewId] ?: run {
                    result.viewNotFound(viewId); return
                }
                view.setExpression(index, commandError(result)) {
                    mainHandler.post { result.success(null) }
                }
            }

            "setParameter" -> {
                val viewId = call.requireInt("viewId", result) ?: return
                val parameterId = call.requireNonEmptyString("parameterId", result) ?: return
                val value = call.argument<Double>("value")?.toFloat()
                if (value == null) {
                    result.error("INVALID_ARGS", "Missing 'value'", null); return
                }
                val view = viewRegistry[viewId] ?: run {
                    result.viewNotFound(viewId); return
                }
                view.setParameter(parameterId, value, commandError(result)) {
                    mainHandler.post { result.success(null) }
                }
            }

            "setMotionSpeed" -> {
                val viewId = call.requireInt("viewId", result) ?: return
                val speed = call.argument<Double>("speed")?.toFloat()
                if (speed == null) {
                    result.error("INVALID_ARGS", "Missing 'speed'", null); return
                }
                val view = viewRegistry[viewId] ?: run {
                    result.viewNotFound(viewId); return
                }
                view.setMotionSpeed(speed, commandError(result)) {
                    mainHandler.post { result.success(null) }
                }
            }

            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        viewRegistry.values.toList().forEach { it.dispose() }
        viewRegistry.clear()
    }

    private fun commandError(result: Result): Live2DCommandError = { code, message ->
        mainHandler.post { result.error(code, message, null) }
    }
}

private fun MethodCall.requireInt(name: String, result: Result): Int? {
    val value = argument<Int>(name)
    if (value == null) {
        result.error("INVALID_ARGS", "Missing or invalid '$name'", null)
        return null
    }
    return value
}

private fun MethodCall.requireString(name: String, result: Result): String? {
    val value = argument<String>(name)
    if (value == null) {
        result.error("INVALID_ARGS", "Missing '$name'", null)
        return null
    }
    return value
}

private fun MethodCall.requireNonEmptyString(name: String, result: Result): String? {
    val value = argument<String>(name)
    if (value.isNullOrEmpty()) {
        result.error("INVALID_ARGS", "Missing or empty '$name'", null)
        return null
    }
    return value
}

private fun Result.viewNotFound(viewId: Int) {
    error("VIEW_NOT_FOUND", "No Live2D view registered for id $viewId", null)
}
