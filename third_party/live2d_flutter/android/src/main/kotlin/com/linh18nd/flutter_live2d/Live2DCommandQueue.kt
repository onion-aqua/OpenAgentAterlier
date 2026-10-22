package com.linh18nd.flutter_live2d

import java.util.concurrent.ConcurrentLinkedQueue

/** Commands wait for their own surface, preserve per-view order, and terminate once. */
internal class Live2DCommandQueue(
    private val clock: () -> Long,
    private val timeoutMs: Long = 10_000,
) {
    private class Command(
        val handle: Long,
        val needsSurface: Boolean,
        val deadline: Long,
        val onError: (String, String) -> Unit,
        val action: () -> Unit,
    )

    private val pending = ConcurrentLinkedQueue<Command>()
    private val lock = Any()

    fun submit(
        handle: Long,
        needsSurface: Boolean = true,
        onError: (String, String) -> Unit,
        action: () -> Unit,
    ) {
        synchronized(lock) {
            pending.offer(Command(handle, needsSurface, clock() + timeoutMs, onError, action))
        }
    }

    /** Called only by the render thread. [execute] returns false until GL is ready. */
    fun drain(
        exists: (Long) -> Boolean,
        execute: (Long, Boolean, () -> Unit) -> Boolean,
    ) {
        val blocked = mutableSetOf<Long>()
        val deferred = mutableListOf<Command>()
        val batch = synchronized(lock) {
            buildList { while (true) add(pending.poll() ?: break) }
        }
        for (command in batch) {
            try {
                when {
                    !exists(command.handle) -> command.onError(
                        "VIEW_NOT_FOUND", "The Live2D view was disposed.",
                    )
                    clock() >= command.deadline -> command.onError(
                        "SURFACE_NOT_READY", "The Live2D surface did not become ready in time.",
                    )
                    command.handle in blocked -> deferred.add(command)
                    !execute(command.handle, command.needsSurface, command.action) -> {
                        blocked.add(command.handle)
                        deferred.add(command)
                    }
                }
            } catch (_: Throwable) {
                // Do not put native errors, model paths or user text into logs/replies.
                command.onError("NATIVE_ERROR", "The Live2D render command failed.")
            }
        }
        // Submissions can arrive during dispatch. Put older deferred work first.
        synchronized(lock) {
            val newer = mutableListOf<Command>()
            while (true) newer.add(pending.poll() ?: break)
            deferred.forEach(pending::offer)
            newer.forEach(pending::offer)
        }
    }

    fun failAll(code: String, message: String) {
        val batch = synchronized(lock) {
            buildList { while (true) add(pending.poll() ?: break) }
        }
        batch.forEach { it.onError(code, message) }
    }
}
