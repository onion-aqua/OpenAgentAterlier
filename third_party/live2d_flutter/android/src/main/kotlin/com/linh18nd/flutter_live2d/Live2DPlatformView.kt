package com.linh18nd.flutter_live2d

import android.content.Context
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.os.SystemClock
import android.util.Log
import android.view.MotionEvent
import android.view.TextureView
import android.view.View
import io.flutter.plugin.platform.PlatformView
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

typealias Live2DCommandError = (String, String) -> Unit

class Live2DPlatformView(
    context: Context,
    private val viewId: Int,
    private val onDisposed: (Int) -> Unit,
) : PlatformView {
    companion object {
        private var assetManagerSet = false
    }

    private val nativeHandle: Long
    private val renderView: Live2DTextureView

    init {
        if (!assetManagerSet) {
            Live2DBridge.nativeSetAssetManager(context.assets)
            assetManagerSet = true
        }
        nativeHandle = Live2DBridge.nativeCreateView()
        // Register before Flutter's platform-view callback can submit commands.
        Live2DRenderHub.registerHandle(nativeHandle)
        renderView = Live2DTextureView(context, nativeHandle)
    }

    override fun getView(): View = renderView

    override fun dispose() {
        Live2DRenderHub.disposeViewSync(nativeHandle)
        onDisposed(viewId)
    }

    fun loadModel(
        modelDir: String,
        modelFileName: String,
        onError: Live2DCommandError,
        callback: (Boolean) -> Unit,
    ) {
        Live2DRenderHub.queueEvent(nativeHandle, onError = onError) {
            val ok = Live2DBridge.nativeLoadModel(nativeHandle, modelDir, modelFileName)
            Live2DRenderHub.rememberModel(nativeHandle, if (ok) modelDir to modelFileName else null)
            Log.i("FlutterLive2D", "Model load completed: success=$ok")
            callback(ok)
        }
    }

    fun unloadModel(onError: Live2DCommandError, callback: () -> Unit) {
        Live2DRenderHub.queueEvent(nativeHandle, needsSurface = false, onError = onError) {
            Live2DBridge.nativeUnloadModel(nativeHandle)
            Live2DRenderHub.rememberModel(nativeHandle, null)
            callback()
        }
    }

    fun setRenderingPaused(paused: Boolean, onError: Live2DCommandError, callback: () -> Unit) {
        Live2DRenderHub.queueEvent(nativeHandle, needsSurface = false, onError = onError) {
            Live2DRenderHub.setPaused(nativeHandle, paused)
            callback()
        }
    }

    fun startMotion(
        group: String, index: Int, priority: Int,
        onError: Live2DCommandError, callback: () -> Unit,
    ) {
        Live2DRenderHub.queueEvent(nativeHandle, onError = onError) {
            Live2DBridge.nativeStartMotion(nativeHandle, group, index, priority)
            callback()
        }
    }

    fun setIdleMotion(
        group: String, index: Int,
        onError: Live2DCommandError, callback: () -> Unit,
    ) {
        Live2DRenderHub.queueEvent(nativeHandle, onError = onError) {
            if (!Live2DBridge.nativeSetIdleMotion(nativeHandle, group, index)) {
                onError(
                    "INVALID_MOTION",
                    "Idle motion '$group[$index]' is not present in the loaded model.",
                )
            } else {
                Live2DRenderHub.rememberIdleMotion(nativeHandle, group, index)
                callback()
            }
        }
    }

    fun setExpression(index: Int, onError: Live2DCommandError, callback: () -> Unit) {
        Live2DRenderHub.queueEvent(nativeHandle, onError = onError) {
            Live2DBridge.nativeSetExpression(nativeHandle, index)
            callback()
        }
    }

    fun setParameter(
        parameterId: String, value: Float,
        onError: Live2DCommandError, callback: () -> Unit,
    ) {
        Live2DRenderHub.queueEvent(nativeHandle, onError = onError) {
            Live2DBridge.nativeSetParameter(nativeHandle, parameterId, value)
            callback()
        }
    }

    fun setMotionSpeed(speed: Float, onError: Live2DCommandError, callback: () -> Unit) {
        Live2DRenderHub.queueEvent(nativeHandle, onError = onError) {
            Live2DBridge.nativeSetMotionSpeed(nativeHandle, speed)
            callback()
        }
    }
}

private class Live2DTextureView(
    context: Context,
    private val nativeHandle: Long,
) : TextureView(context), TextureView.SurfaceTextureListener {
    init {
        surfaceTextureListener = this
        isOpaque = false
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val x = event.x
        val y = event.y
        when (event.action) {
            MotionEvent.ACTION_DOWN -> Live2DRenderHub.queueEvent(nativeHandle) {
                Live2DBridge.nativeOnTouchBegan(nativeHandle, x, y)
            }
            MotionEvent.ACTION_MOVE -> Live2DRenderHub.queueEvent(nativeHandle) {
                Live2DBridge.nativeOnTouchMoved(nativeHandle, x, y)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> Live2DRenderHub.queueEvent(nativeHandle) {
                Live2DBridge.nativeOnTouchEnded(nativeHandle, x, y)
            }
        }
        return true
    }

    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
        Live2DRenderHub.registerSurface(nativeHandle, surface, width, height)
    }

    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {
        Live2DRenderHub.setSurfaceSize(nativeHandle, width, height)
    }

    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        // The hub owns release until EGL stops using this texture. The native
        // handle survives temporary surface loss and is freed only by dispose.
        Live2DRenderHub.releaseSurface(nativeHandle, surface)
        return false
    }

    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
}

/** One EGL context owns all Cubism rendering and native resource destruction. */
private object Live2DRenderHub {
    private const val TAG = "FlutterLive2D"

    private data class IdleMotion(val group: String = "Idle", val index: Int = 0)

    private class HubView(val handle: Long) {
        var surfaceTexture: SurfaceTexture? = null
        var width = 0
        var height = 0
        var paused = false
        var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
        var initialized = false
        var sizeDirty = true
        var loadedModel: Pair<String, String>? = null
        var idleMotion = IdleMotion()
        @Volatile var doomed = false
        @Volatile var disposeLatch: CountDownLatch? = null
    }

    private val lock = Any()
    private val views = mutableMapOf<Long, HubView>()
    private val controls = ConcurrentLinkedQueue<() -> Unit>()
    private val commands = Live2DCommandQueue(SystemClock::uptimeMillis)
    @Volatile private var running = false
    @Volatile private var failure: String? = null
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglConfig: EGLConfig? = null
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var cleanupSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    fun registerHandle(handle: Long) {
        synchronized(lock) {
            views[handle] = HubView(handle)
            if (!running) {
                running = true
                failure = null
                Thread({ renderLoop() }, "Live2D-RenderHub").start()
            }
        }
    }

    fun registerSurface(handle: Long, surface: SurfaceTexture, width: Int, height: Int) {
        controls.offer {
            val view = synchronized(lock) { views[handle] }
            if (view != null && !view.doomed) {
                destroySurface(view)
                view.surfaceTexture = surface
                view.width = width
                view.height = height
                val cfg = eglConfig
                if (cfg != null) {
                    view.eglSurface = EGL14.eglCreateWindowSurface(
                        eglDisplay, cfg, surface, intArrayOf(EGL14.EGL_NONE), 0,
                    )
                }
                if (ensureReady(view)) {
                    view.loadedModel?.let { (dir, file) ->
                        val ok = Live2DBridge.nativeLoadModel(handle, dir, file)
                        if (ok && view.idleMotion != IdleMotion()) {
                            val idle = view.idleMotion
                            if (!Live2DBridge.nativeSetIdleMotion(handle, idle.group, idle.index)) {
                                Log.w(TAG, "Configured idle motion was unavailable after surface restore")
                            }
                        }
                        Log.i(TAG, "Model surface restored: success=$ok")
                    }
                }
            }
        }
    }

    fun releaseSurface(handle: Long, surface: SurfaceTexture) {
        controls.offer {
            val view = synchronized(lock) { views[handle] }
            if (view?.surfaceTexture === surface) destroySurface(view)
            surface.release()
        }
    }

    fun setSurfaceSize(handle: Long, width: Int, height: Int) {
        controls.offer {
            synchronized(lock) { views[handle] }?.let {
                it.width = width
                it.height = height
                it.sizeDirty = true
            }
        }
    }

    fun queueEvent(
        handle: Long,
        needsSurface: Boolean = true,
        onError: Live2DCommandError = { code, _ -> Log.w(TAG, "Command rejected: $code") },
        action: () -> Unit,
    ) {
        synchronized(lock) {
            val problem = failure
            when {
                problem != null -> onError("EGL_ERROR", problem)
                views[handle]?.doomed != false -> onError("VIEW_NOT_FOUND", "The Live2D view was disposed.")
                else -> commands.submit(handle, needsSurface, onError, action)
            }
        }
    }

    // Both methods are called only by the render hub's dispatched commands.
    fun rememberModel(handle: Long, model: Pair<String, String>?) {
        synchronized(lock) { views[handle] }?.let {
            it.loadedModel = model
            // A deliberate load/unload starts the next model at Idle[0]. A
            // temporary surface restore bypasses this method and reapplies the
            // configured value above without dispatching a second motion.
            it.idleMotion = IdleMotion()
        }
    }

    fun rememberIdleMotion(handle: Long, group: String, index: Int) {
        synchronized(lock) { views[handle] }?.idleMotion = IdleMotion(group, index)
    }

    fun setPaused(handle: Long, paused: Boolean) {
        synchronized(lock) { views[handle] }?.paused = paused
    }

    fun disposeViewSync(handle: Long) {
        val latch = synchronized(lock) {
            val view = views[handle] ?: return
            if (view.doomed) view.disposeLatch ?: return
            else CountDownLatch(1).also {
                view.doomed = true
                view.disposeLatch = it
            }
        }
        try {
            // Cleanup remains queued even on timeout; no main-thread free can
            // race the render thread, and TextureView release is owned above.
            if (!latch.await(2_000, TimeUnit.MILLISECONDS)) Log.w(TAG, "Native cleanup remains queued")
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun renderLoop() {
        try {
            check(initEgl()) { "EGL initialization failed" }
            while (running) {
                while (true) (controls.poll() ?: break).invoke()
                val snapshot = synchronized(lock) { views.values.toList() }
                snapshot.filter { it.doomed }.forEach(::destroyView)
                commands.drain(
                    exists = { handle -> synchronized(lock) { views[handle]?.doomed == false } },
                    execute = { handle, needsSurface, action ->
                        val view = synchronized(lock) { views[handle] }
                        if (view == null || view.doomed) false
                        else if (needsSurface && !ensureReady(view)) false
                        else if (!needsSurface && !makeCurrent(view.eglSurface)) false
                        else {
                            action()
                            true
                        }
                    },
                )
                var anyDrawn = false
                synchronized(lock) { views.values.toList() }.forEach { view ->
                    if (!view.doomed && !view.paused && ensureReady(view)) {
                        Live2DBridge.nativeOnDrawFrame(view.handle)
                        EGL14.eglSwapBuffers(eglDisplay, view.eglSurface)
                        anyDrawn = true
                    }
                }
                SystemClock.sleep(if (anyDrawn) 16 else 25)
            }
        } catch (_: Throwable) {
            synchronized(lock) { failure = "The Live2D render context is unavailable." }
            Log.e(TAG, "Render context failed")
        } finally {
            commands.failAll("EGL_ERROR", "The Live2D render context is unavailable.")
            // Also resolve surface ownership and cleanup latches after EGL failure.
            while (true) {
                val control = controls.poll() ?: break
                try { control() } catch (_: Throwable) { Log.w(TAG, "Surface cleanup failed") }
            }
            synchronized(lock) { views.values.toList() }.forEach(::destroyView)
            if (cleanupSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, cleanupSurface)
            cleanupSurface = EGL14.EGL_NO_SURFACE
            EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
            eglContext = EGL14.EGL_NO_CONTEXT
            synchronized(lock) { running = false }
        }
    }

    /** Run before any model command, including the first frame and paused loads. */
    private fun ensureReady(view: HubView): Boolean {
        if (view.doomed || view.width <= 0 || view.height <= 0 ||
            view.eglSurface == EGL14.EGL_NO_SURFACE || !makeCurrent(view.eglSurface)) return false
        if (!view.initialized) {
            Live2DBridge.nativeOnSurfaceCreated(view.handle)
            view.initialized = true
            view.sizeDirty = true
        }
        if (view.sizeDirty) {
            Live2DBridge.nativeOnSurfaceChanged(view.handle, view.width, view.height)
            view.sizeDirty = false
        }
        return true
    }

    private fun makeCurrent(surface: EGLSurface): Boolean {
        val target = if (surface == EGL14.EGL_NO_SURFACE) cleanupSurface else surface
        return target != EGL14.EGL_NO_SURFACE &&
            EGL14.eglMakeCurrent(eglDisplay, target, target, eglContext)
    }

    private fun destroySurface(view: HubView) {
        if (view.eglSurface != EGL14.EGL_NO_SURFACE) {
            if (makeCurrent(view.eglSurface) && view.initialized) {
                Live2DBridge.nativeOnSurfaceDestroyed(view.handle)
            }
            makeCurrent(cleanupSurface)
            EGL14.eglDestroySurface(eglDisplay, view.eglSurface)
        }
        view.eglSurface = EGL14.EGL_NO_SURFACE
        view.surfaceTexture = null
        view.initialized = false
        view.sizeDirty = true
    }

    private fun destroyView(view: HubView) {
        try {
            destroySurface(view)
            makeCurrent(cleanupSurface)
            Live2DBridge.nativeDestroyView(view.handle)
        } finally {
            synchronized(lock) { views.remove(view.handle) }
            view.disposeLatch?.countDown()
        }
    }

    private fun initEgl(): Boolean {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) return false
        val version = IntArray(2)
        if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) return false
        val configAttribs = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8, EGL14.EGL_DEPTH_SIZE, 16, EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        if (!EGL14.eglChooseConfig(eglDisplay, configAttribs, 0, configs, 0, 1, count, 0) || count[0] <= 0) return false
        eglConfig = configs[0]
        eglContext = EGL14.eglCreateContext(
            eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
        if (eglContext == EGL14.EGL_NO_CONTEXT) return false
        cleanupSurface = EGL14.eglCreatePbufferSurface(
            eglDisplay, eglConfig,
            intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0,
        )
        return makeCurrent(cleanupSurface)
    }
}
