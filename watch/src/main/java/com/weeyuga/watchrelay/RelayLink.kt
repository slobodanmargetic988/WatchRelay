package com.weeyuga.watchrelay

import android.net.ConnectivityManager
import java.io.IOException
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

internal class RelayLink(
    private val connectivity: ConnectivityManager,
    private val log: Diagnostics,
    private val send: (type: Int, streamId: Long, payload: ByteArray) -> Unit,
    private val closeTransport: () -> Unit,
) : AutoCloseable {
    private val lock = Object()
    private var highestId = 0L
    private val streams = mutableMapOf<Long, Stream>()
    private var inboundQueued = 0
    private var inboundHighWater = 0
    private var closed = false
    private val abortedIds = ArrayDeque<Long>(RECENT_ABORT_LIMIT)
    private val readers = workers("WatchRelay TCP read")
    private val writers = workers("WatchRelay TCP write")

    fun handle(frame: ProbeProtocol.Frame) = synchronized(lock) {
        if (closed) throw IOException()
        if (frame.type == ProbeProtocol.OPEN) {
            open(frame)
            return@synchronized
        }
        val stream = streams[frame.streamId]
        if (stream == null) {
            val lateControl = frame.type == ProbeProtocol.CLOSE || frame.type == ProbeProtocol.WINDOW_UPDATE
            if (frame.streamId <= highestId && (lateControl || frame.streamId in abortedIds)) {
                return@synchronized
            }
            throw ProbeProtocol.ProtocolError()
        }
        when (frame.type) {
            ProbeProtocol.CLOSE -> {
                val code = frame.payload[0].toInt()
                if (code == 0) throw ProbeProtocol.ProtocolError()
                stream.finish(code, notifyPeer = false)
            }
            ProbeProtocol.DATA -> stream.receive(frame.payload)
            ProbeProtocol.HALF_CLOSE -> stream.receiveEof()
            ProbeProtocol.WINDOW_UPDATE -> stream.grantCredit(ByteBuffer.wrap(frame.payload).int)
            else -> throw ProbeProtocol.ProtocolError()
        }
    }

    private fun open(frame: ProbeProtocol.Frame) {
        if (frame.streamId <= highestId) throw ProbeProtocol.ProtocolError()
        highestId = frame.streamId
        val destination = try {
            ProbeProtocol.readDestination(frame.payload)
        } catch (failure: RelayOpenFailure) {
            reject(frame.streamId, failure.socksCode, "INVALID_DESTINATION")
            return
        }
        if (streams.size >= STREAM_LIMIT) {
            reject(frame.streamId, 1, "STREAM_LIMIT")
            return
        }
        val stream = Stream(frame.streamId, destination)
        streams[stream.id] = stream
        log.record("stream_opening", "stream" to stream.id, "active_streams" to streams.size)
        try {
            readers.execute(stream.readTask)
        } catch (e: RejectedExecutionException) {
            stream.finish(1, notifyPeer = true)
        }
    }

    private fun reject(id: Long, code: Int, reason: String) {
        log.record("stream_open_error", "stream" to id, "socks_code" to code, "reason" to reason)
        send(ProbeProtocol.OPEN_ERR, id, byteArrayOf(code.toByte()))
    }

    override fun close() = synchronized(lock) {
        if (closed) return@synchronized
        closed = true
        streams.values.toList().forEach { it.finish(2, notifyPeer = false) }
        readers.shutdownNow()
        writers.shutdownNow()
        log.record("stream_queue_summary", "rx_high_water_bytes" to inboundHighWater)
    }

    private inner class Stream(val id: Long, val destination: RelayDestination) {
        private val connector = CellularConnector(connectivity, log, ::cellularLost)
        val readTask = Runnable { connectAndRead() }
        private var writeTask: Runnable? = null
        private var ready = false
        private var localEof = false
        private var remoteEof = false
        private var remoteEofApplied = false
        private var receiveCredit = ProbeProtocol.INITIAL_CREDIT
        private var sendCredit = ProbeProtocol.INITIAL_CREDIT
        private val incoming = ByteArray(ProbeProtocol.INITIAL_CREDIT)
        private var head = 0
        private var queued = 0
        private var highWater = 0
        private var downloaded = 0L
        private var uploaded = 0L

        private fun connectAndRead() {
            try {
                val socket = connector.connect(destination)
                synchronized(lock) {
                    if (streams[id] !== this) return
                    if (connector.networkLost) throw RelayOpenFailure(3)
                    val writer = Runnable { writeTcp(socket) }
                    writeTask = writer
                    writers.execute(writer)
                    send(ProbeProtocol.OPEN_OK, id, ProbeProtocol.boundAddress(socket))
                    ready = true
                    log.record(
                        "stream_opened", "stream" to id, "transport" to "CELLULAR",
                        "credit_bytes" to ProbeProtocol.INITIAL_CREDIT,
                    )
                }
                readTcp(socket)
            } catch (e: RejectedExecutionException) {
                fail(1)
            } catch (e: RelayOpenFailure) {
                fail(1, e.socksCode)
            } catch (e: IOException) {
                fail(1)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                fail(2)
            }
        }

        private fun readTcp(socket: Socket) {
            val input = socket.getInputStream()
            val buffer = ByteArray(ProbeProtocol.DATA_MAX)
            while (true) {
                val limit = synchronized(lock) {
                    while (streams[id] === this && sendCredit == 0) lock.wait()
                    if (streams[id] !== this) return
                    minOf(sendCredit, buffer.size)
                }
                val count = input.read(buffer, 0, limit)
                synchronized(lock) {
                    if (streams[id] !== this) return
                    if (count == -1) {
                        send(ProbeProtocol.HALF_CLOSE, id, EMPTY)
                        localEof = true
                        finishIfDrained()
                        return
                    }
                    if (count > 0) {
                        sendCredit -= count
                        send(ProbeProtocol.DATA, id, buffer.copyOf(count))
                        downloaded += count
                    }
                }
            }
        }

        private fun writeTcp(socket: Socket) {
            try {
                val output = socket.getOutputStream()
                val buffer = ByteArray(ProbeProtocol.DATA_MAX)
                while (true) {
                    val count = synchronized(lock) {
                        while (streams[id] === this && queued == 0 && !remoteEof) lock.wait()
                        if (streams[id] !== this) return
                        if (queued == 0) break
                        take(buffer)
                    }
                    output.write(buffer, 0, count)
                    synchronized(lock) {
                        if (streams[id] !== this) return
                        uploaded += count
                        receiveCredit += count
                        send(ProbeProtocol.WINDOW_UPDATE, id, ByteBuffer.allocate(4).putInt(count).array())
                    }
                }
                socket.shutdownOutput()
                synchronized(lock) {
                    if (streams[id] !== this) return
                    remoteEofApplied = true
                    finishIfDrained()
                }
            } catch (e: IOException) {
                fail(1)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                fail(2)
            }
        }

        fun receive(payload: ByteArray) {
            if (!ready || remoteEof || payload.size > receiveCredit ||
                payload.size > RelayOutbox.GLOBAL_DATA_LIMIT - inboundQueued
            ) throw ProbeProtocol.ProtocolError()
            val tail = (head + queued) % incoming.size
            val first = minOf(payload.size, incoming.size - tail)
            payload.copyInto(incoming, tail, 0, first)
            payload.copyInto(incoming, 0, first, payload.size)
            receiveCredit -= payload.size
            queued += payload.size
            inboundQueued += payload.size
            inboundHighWater = maxOf(inboundHighWater, inboundQueued)
            highWater = maxOf(highWater, queued)
            lock.notifyAll()
        }

        private fun take(buffer: ByteArray): Int {
            val count = minOf(queued, buffer.size)
            val first = minOf(count, incoming.size - head)
            incoming.copyInto(buffer, 0, head, head + first)
            incoming.copyInto(buffer, first, 0, count - first)
            head = (head + count) % incoming.size
            queued -= count
            inboundQueued -= count
            return count
        }

        fun receiveEof() {
            if (!ready || remoteEof) throw ProbeProtocol.ProtocolError()
            remoteEof = true
            lock.notifyAll()
        }

        fun grantCredit(bytes: Int) {
            if (!ready || bytes > ProbeProtocol.INITIAL_CREDIT - sendCredit) {
                throw ProbeProtocol.ProtocolError()
            }
            sendCredit += bytes
            lock.notifyAll()
        }

        private fun finishIfDrained() {
            if (localEof && remoteEofApplied) finish(0, notifyPeer = true)
        }

        private fun cellularLost() = fail(4, 3)

        private fun fail(code: Int, socksCode: Int = 1) {
            try {
                synchronized(lock) {
                    if (connector.networkLost) finish(4, notifyPeer = true, socksCode = 3)
                    else finish(code, notifyPeer = true, socksCode = socksCode)
                }
            } catch (e: IOException) {
                closeTransport()
            }
        }

        fun finish(code: Int, notifyPeer: Boolean, socksCode: Int = 1) {
            if (streams[id] !== this) return
            streams.remove(id)
            readers.remove(readTask)
            writeTask?.let(writers::remove)
            inboundQueued -= queued
            if (code != 0) {
                if (abortedIds.size == RECENT_ABORT_LIMIT) abortedIds.removeFirst()
                abortedIds.addLast(id)
            }
            lock.notifyAll()
            connector.close()
            log.record(
                "stream_closed", "stream" to id, "code" to code, "opened" to ready,
                "tcp_rx_bytes" to downloaded, "tcp_tx_bytes" to uploaded,
                "queue_high_water_bytes" to highWater,
            )
            if (notifyPeer && !closed) {
                if (ready) send(ProbeProtocol.CLOSE, id, byteArrayOf(code.toByte()))
                else reject(id, socksCode, if (code == 4) "CELLULAR_LOST" else "CONNECT_FAILED")
            }
        }
    }

    companion object {
        private const val STREAM_LIMIT = 24
        private const val RECENT_ABORT_LIMIT = 64
        private val EMPTY = ByteArray(0)

        private fun workers(name: String) = ThreadPoolExecutor(
            STREAM_LIMIT, STREAM_LIMIT, 10, TimeUnit.SECONDS, ArrayBlockingQueue(STREAM_LIMIT),
        ) { task -> Thread(task, name).apply { isDaemon = true } }.apply {
            // A just-retired stream may have released its slot before its workers return.
            allowCoreThreadTimeOut(true)
        }
    }
}
