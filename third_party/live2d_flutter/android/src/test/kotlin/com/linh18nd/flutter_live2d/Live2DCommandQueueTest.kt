package com.linh18nd.flutter_live2d

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class Live2DCommandQueueTest {
    @Test
    fun `load waits for surface while earlier unload can finish`() {
        val queue = Live2DCommandQueue({ 0 })
        val events = mutableListOf<String>()
        var ready = false
        queue.submit(1, false, { code, _ -> events.add(code) }) { events.add("unloaded") }
        queue.submit(1, true, { code, _ -> events.add(code) }) { events.add("loaded") }
        fun drain() = queue.drain({ true }) { _, needsSurface, action ->
            if (needsSurface && !ready) false else { action(); true }
        }
        drain()
        assertEquals(listOf("unloaded"), events)
        ready = true
        drain()
        drain()
        assertEquals(listOf("unloaded", "loaded"), events)
    }

    @Test
    fun `waiting view preserves order without blocking another view`() {
        val queue = Live2DCommandQueue({ 0 })
        val events = mutableListOf<String>()
        var firstReady = false
        queue.submit(1, onError = { code, _ -> events.add(code) }) { events.add("a") }
        queue.submit(1, onError = { code, _ -> events.add(code) }) { events.add("b") }
        queue.submit(2, onError = { code, _ -> events.add(code) }) { events.add("other") }
        fun drain() = queue.drain({ true }) { handle, _, action ->
            if (handle == 1L && !firstReady) false else { action(); true }
        }
        drain()
        assertEquals(listOf("other"), events)
        firstReady = true
        drain()
        assertEquals(listOf("other", "a", "b"), events)
    }

    @Test
    fun `surface timeout completes once without executing the command`() {
        var now = 0L
        val queue = Live2DCommandQueue({ now }, timeoutMs = 10)
        val events = mutableListOf<String>()
        queue.submit(1, onError = { code, _ -> events.add(code) }) { events.add("unexpected") }
        queue.drain({ true }) { _, _, _ -> false }
        now = 10
        queue.drain({ true }) { _, _, _ -> false }
        queue.drain({ true }) { _, _, action -> action(); true }
        assertEquals(listOf("SURFACE_NOT_READY"), events)
    }

    @Test
    fun `disposed handles reject every pending command once`() {
        val queue = Live2DCommandQueue({ 0 })
        val events = mutableListOf<String>()
        repeat(2) {
            queue.submit(1, onError = { code, _ -> events.add(code) }) { events.add("unexpected") }
        }
        queue.drain({ false }) { _, _, action -> action(); true }
        queue.drain({ false }) { _, _, action -> action(); true }
        assertEquals(listOf("VIEW_NOT_FOUND", "VIEW_NOT_FOUND"), events)
    }

    @Test
    fun `failure does not swallow later commands or expose private details`() {
        val queue = Live2DCommandQueue({ 0 })
        val events = mutableListOf<String>()
        queue.submit(1, onError = { code, message -> events.add("$code:$message") }) {
            error("private model path and dialogue")
        }
        queue.submit(1, onError = { code, _ -> events.add(code) }) { events.add("next") }
        queue.drain({ true }) { _, _, action -> action(); true }
        assertEquals(listOf("NATIVE_ERROR:The Live2D render command failed.", "next"), events)
    }

    @Test
    fun `new work cannot overtake deferred commands`() {
        val queue = Live2DCommandQueue({ 0 })
        val events = mutableListOf<Int>()
        val reject: (String, String) -> Unit = { code, _ -> error(code) }
        queue.submit(1, onError = reject) { events.add(1) }
        queue.submit(1, onError = reject) { events.add(2) }
        var submitted = false
        queue.drain({ true }) { _, _, _ ->
            if (!submitted) {
                submitted = true
                queue.submit(1, onError = reject) { events.add(3) }
            }
            false
        }
        queue.drain({ true }) { _, _, action -> action(); true }
        assertEquals(listOf(1, 2, 3), events)
    }

    @Test
    fun `render failure completes queued requests once`() {
        val queue = Live2DCommandQueue({ 0 })
        val events = mutableListOf<String>()
        queue.submit(1, onError = { code, _ -> events.add(code) }) { events.add("unexpected") }
        queue.failAll("EGL_ERROR", "Unavailable")
        queue.failAll("EGL_ERROR", "Unavailable")
        assertEquals(listOf("EGL_ERROR"), events)
    }
}
