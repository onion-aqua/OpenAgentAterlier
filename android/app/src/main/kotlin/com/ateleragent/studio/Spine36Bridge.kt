package com.ateleragent.studio

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONObject
import java.io.ByteArrayInputStream

/** Separate offline 3.6 engine; never sends legacy data into spine-cpp 4.2. */
class Spine36Bridge(private val activity: Activity, engine: FlutterEngine) {
    private val messenger = engine.dartExecutor.binaryMessenger
    private val channel = MethodChannel(messenger, "agentatelier/spine36")
    private val validations = mutableSetOf<Spine36Surface>()

    init {
        engine.platformViewsController.registry.registerViewFactory(
            "agentatelier/spine36", object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, id: Int, args: Any?): PlatformView {
                    return Spine36Surface(context, args, messenger, id)
                }
            },
        )
        channel.setMethodCallHandler { call, result ->
            if (call.method != "validate") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val parent = activity.window.decorView as ViewGroup
                lateinit var surface: Spine36Surface
                surface = Spine36Surface(activity, call.arguments, onEvent = { type, value ->
                    if (validations.remove(surface)) {
                        parent.removeView(surface.getView())
                        surface.dispose()
                        if (type == "ready") result.success(value)
                        else result.error("spine36_load_failed", value.toString(), null)
                    }
                })
                validations.add(surface)
                // Attached, transparent and one pixel: WebGL executes the same
                // texture/skeleton/draw validation without changing app screens.
                surface.getView().alpha = 0f
                parent.addView(surface.getView(), ViewGroup.LayoutParams(1, 1))
            } catch (error: Exception) {
                result.error("spine36_load_failed", error.message, null)
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        for (surface in validations.toList()) {
            (surface.getView().parent as? ViewGroup)?.removeView(surface.getView())
            surface.cancelValidation()
        }
        validations.clear()
    }
}

private class Spine36Surface(
    context: Context,
    arguments: Any?,
    messenger: BinaryMessenger? = null,
    id: Int = -1,
    private val onEvent: ((String, Any) -> Unit)? = null,
) : PlatformView {
    private val main = Handler(Looper.getMainLooper())
    private val webView = WebView(context)
    private val channel = messenger?.let { MethodChannel(it, "agentatelier/spine36/$id") }
    private var disposed = false
    private var ready = false
    private var reportedFailure = false
    private var performance: String? = null
    private val origin = "https://spine36.local/"
    private val timeout = Runnable { report("error", "Spine 3.6 loading timed out") }
    private val resources: Map<String, Pair<String, ByteArray>>

    init {
        val params = arguments as? Map<*, *> ?: error("Missing Spine 3.6 model")
        fun bytes(key: String): ByteArray = params[key] as? ByteArray ?: error("Missing $key")
        resources = mapOf(
            "/model/model.json" to ("application/json" to bytes("skeleton")),
            "/model/model.atlas" to ("text/plain" to bytes("atlas")),
            "/model/texture.png" to ("image/png" to bytes("texture")),
        )
        require(resources.values.sumOf { it.second.size.toLong() } <= 64L * 1024 * 1024)
        webView.setBackgroundColor(Color.TRANSPARENT)
        webView.settings.apply {
            javaScriptEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            domStorageEnabled = false
            blockNetworkLoads = true
            mediaPlaybackRequiresUserGesture = true
        }
        webView.isVerticalScrollBarEnabled = false
        webView.isHorizontalScrollBarEnabled = false
        webView.addJavascriptInterface(object {
            @JavascriptInterface
            fun postMessage(message: String) {
                main.post {
                    if (disposed) return@post
                    try {
                        val event = JSONObject(message)
                        when (event.getString("type")) {
                            "ready" -> {
                                val array = event.getJSONArray("value")
                                report("ready", List(array.length()) { array.getString(it) })
                            }
                            "error" -> report("error", event.optString("value", "Spine 3.6 failed"))
                        }
                    } catch (_: Exception) {
                        report("error", "Invalid Spine 3.6 runtime response")
                    }
                }
            }
        }, "Spine36Host")
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = true

            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
                val uri = request.url
                if (uri.scheme != "https" || uri.host != "spine36.local" || request.method != "GET") {
                    return missing()
                }
                val path = uri.path ?: return missing()
                resources[path]?.let { (mime, data) ->
                    return WebResourceResponse(mime, if (mime == "image/png") null else "UTF-8", ByteArrayInputStream(data))
                }
                val mime = when (path) {
                    "/index.html" -> "text/html"
                    "/player.js", "/spine-webgl.js" -> "application/javascript"
                    else -> return missing()
                }
                return WebResourceResponse(mime, "UTF-8", context.assets.open("spine36/${path.drop(1)}"))
            }
        }
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "performance" -> {
                    val params = call.arguments as? Map<*, *>
                    if (params == null || disposed) {
                        result.error("spine36_state", "Player disposed or invalid performance", null)
                    } else {
                        performance = JSONObject(params).toString()
                        if (ready) updatePerformance()
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        main.postDelayed(timeout, 20_000)
        webView.loadUrl("${origin}index.html")
    }

    private fun missing() = WebResourceResponse(
        "text/plain", "UTF-8", 404, "Not Found", emptyMap(), ByteArrayInputStream(byteArrayOf()),
    )

    private fun updatePerformance() {
        performance?.let { webView.evaluateJavascript("window.spine36.update($it)", null) }
    }

    private fun report(type: String, value: Any) {
        if (disposed || reportedFailure) return
        main.removeCallbacks(timeout)
        if (type == "ready") {
            ready = true
            updatePerformance()
        } else reportedFailure = true
        channel?.invokeMethod(type, value)
        onEvent?.invoke(type, value)
    }

    fun cancelValidation() {
        report("error", "Spine 3.6 validation cancelled")
        dispose()
    }

    override fun getView(): View = webView

    override fun dispose() {
        if (disposed) return
        disposed = true
        main.removeCallbacks(timeout)
        channel?.setMethodCallHandler(null)
        webView.stopLoading()
        webView.removeJavascriptInterface("Spine36Host")
        webView.destroy()
    }
}
