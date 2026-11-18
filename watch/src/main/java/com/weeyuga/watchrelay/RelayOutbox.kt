package com.weeyuga.watchrelay

import java.nio.ByteBuffer

internal class RelayOutbox {
    private val lock = Object()
    private val ready = LinkedHashMap<Long, Queue>()
    private var queuedBytes = 0
    private var controlFrames = 0
    private var closed = false

    @Volatile var highWaterBytes = 0
        private set

    fun offer(frame: ProbeProtocol.Frame): Boolean = synchronized(lock) {
        if (closed) return false
        val queue = ready[frame.streamId] ?: Queue()
        when (frame.type) {
            ProbeProtocol.DATA -> {
                val size = frame.payload.size
                if (size !in 1..ProbeProtocol.DATA_MAX ||
                    size > ProbeProtocol.INITIAL_CREDIT - queue.dataBytes ||
                    size > GLOBAL_DATA_LIMIT - queuedBytes
                ) return false
                queue.appendData(frame.payload)
                queuedBytes += size
                highWaterBytes = maxOf(highWaterBytes, queuedBytes)
            }
            ProbeProtocol.WINDOW_UPDATE -> {
                if (frame.payload.size != 4) return false
                val bytes = ByteBuffer.wrap(frame.payload).int
                if (bytes !in 1..(ProbeProtocol.INITIAL_CREDIT - queue.windowBytes)) return false
                queue.windowBytes += bytes
            }
            else -> {
                if (controlFrames == CONTROL_LIMIT) return false
                queue.packets.addLast(Packet(frame.type, frame.payload))
                controlFrames++
            }
        }
        ready[frame.streamId] = queue
        lock.notifyAll()
        true
    }

    fun take(): ProbeProtocol.Frame? = synchronized(lock) {
        while (!closed && ready.isEmpty()) lock.wait()
        if (closed) return null
        val iterator = ready.entries.iterator()
        val (id, queue) = iterator.next()
        iterator.remove()
        val nextType = queue.packets.firstOrNull()?.type
        val sendCredit = queue.windowBytes > 0 &&
            nextType != ProbeProtocol.OPEN_OK && (!queue.sentWindowLast || nextType == null)
        val frame = if (sendCredit) {
            val update = ByteBuffer.allocate(4).putInt(queue.windowBytes).array()
            queue.windowBytes = 0
            queue.sentWindowLast = true
            ProbeProtocol.Frame(ProbeProtocol.WINDOW_UPDATE, update, id)
        } else {
            val packet = queue.packets.removeFirst()
            queue.sentWindowLast = false
            if (packet.type == ProbeProtocol.DATA) {
                queue.dataBytes -= packet.size
                queuedBytes -= packet.size
            } else {
                controlFrames--
            }
            val payload = if (packet.size == packet.bytes.size) packet.bytes else packet.bytes.copyOf(packet.size)
            ProbeProtocol.Frame(packet.type, payload, id)
        }
        if (queue.packets.isNotEmpty() || queue.windowBytes > 0) ready[id] = queue
        frame
    }

    fun close() = synchronized(lock) {
        closed = true
        ready.clear()
        lock.notifyAll()
    }

    private class Queue {
        val packets = ArrayDeque<Packet>()
        var dataBytes = 0
        var windowBytes = 0
        var sentWindowLast = false

        fun appendData(payload: ByteArray) {
            val tail = packets.lastOrNull()?.takeIf { it.type == ProbeProtocol.DATA }
            val copied = if (tail == null) 0 else minOf(payload.size, tail.bytes.size - tail.size)
            if (tail != null && copied > 0) {
                payload.copyInto(tail.bytes, tail.size, 0, copied)
                tail.size += copied
            }
            if (copied < payload.size) {
                val size = payload.size - copied
                val bytes = ByteArray(ProbeProtocol.DATA_MAX)
                payload.copyInto(bytes, 0, copied)
                packets.addLast(Packet(ProbeProtocol.DATA, bytes, size))
            }
            dataBytes += payload.size
        }
    }

    private class Packet(val type: Int, val bytes: ByteArray, var size: Int = bytes.size)

    companion object {
        const val GLOBAL_DATA_LIMIT = 2 * 1024 * 1024
        const val CONTROL_LIMIT = 128
    }
}
