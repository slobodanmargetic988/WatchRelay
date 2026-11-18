package com.weeyuga.watchrelay

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.os.SystemClock
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.IOException
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

internal interface ProbePeer {
    val connected: Boolean
}

@SuppressLint("MissingPermission") // The activity requests BLUETOOTH_CONNECT before starting.
internal class BluetoothProbeServer(
    private val adapter: BluetoothAdapter?,
    private val preferences: SharedPreferences,
    private val log: Diagnostics,
    private val scheduler: ScheduledExecutorService,
    private val connectivity: ConnectivityManager,
    private val automaticPeer: String?,
    private val onStatus: (status: String, pendingName: String?) -> Unit,
    private val onChannel: (Int?) -> Unit,
    private val runProbe: (ProbePeer, (ProbeResult) -> Unit) -> Unit,
    private val cancelProbe: (ProbePeer) -> Unit,
) : AutoCloseable {
    private val lock = Any()
    private var listener: BluetoothServerSocket? = null
    private var dialing: BluetoothSocket? = null
    private var link: Link? = null
    private var approval: Approval? = null
    private var stopped = false
    private val thread = Thread({
        if (automaticPeer == null) serve() else connectAutomatically(automaticPeer)
    }, "WatchRelay RFCOMM")
    private val received = AtomicLong()
    private val sent = AtomicLong()
    val rxBytes get() = received.get()
    val txBytes get() = sent.get()
    val connected get() = synchronized(lock) { link?.connected == true }

    fun start() = thread.start()

    private fun serve() {
        try {
            if (adapter?.isEnabled != true) {
                onStatus("Turn on Bluetooth, then restart the session.", null)
                log.record("bluetooth_unavailable")
                return
            }
            val server = adapter.listenUsingRfcommWithServiceRecord(
                ProbeProtocol.SERVICE_NAME, ProbeProtocol.UUID,
            )
            server.use {
                synchronized(lock) {
                    if (stopped) return
                    listener = server
                }
                // The public RFCOMM API assigns the channel. Some firmware exposes it in this
                // diagnostic string, so use it only as a hint for troubleshooting stale SDP.
                val channel = rfcommChannelFromDescription(server.toString())
                onChannel(channel)
                log.record("rfcomm_listening", "secure" to true, "rfcomm_channel" to channel)
                while (true) {
                    onStatus("Waiting for Mac", null)
                    val socket = server.accept()
                    log.record("rfcomm_socket_accepted")
                    serviceLink(socket)
                }
            }
        } catch (e: SecurityException) {
            if (!isStopped()) {
                onChannel(null)
                onStatus("Allow Nearby devices, then restart the session.", null)
                log.record("bluetooth_permission_denied")
            }
        } catch (e: IOException) {
            if (!isStopped()) {
                onChannel(null)
                val code = if (synchronized(lock) { listener == null }) {
                    "sdp_registration_failed"
                } else {
                    "rfcomm_accept_failed"
                }
                log.record(code)
                onStatus("Bluetooth listener failed. Restart the session.", null)
            }
        }
    }

    private fun connectAutomatically(address: String) {
        var backoffMs = 1_000L
        try {
            while (!isStopped()) {
                val device = adapter?.takeIf { it.isEnabled }?.bondedDevices
                    ?.firstOrNull { it.address == address }
                if (device == null) {
                    onStatus("Auto-connect needs the paired Mac", null)
                    log.record("rfcomm_auto_peer_unavailable", "retry_ms" to backoffMs)
                } else {
                    onStatus("Auto · connecting to Mac", null)
                    val outcome = connectToMac(device)
                    if (outcome == LinkOutcome.REJECTED) {
                        onStatus("Mac rejected. Restart auto-connect to try again.", null)
                        return
                    }
                    if (outcome == LinkOutcome.CONNECTED) backoffMs = 1_000L
                    if (isStopped()) return
                    onStatus("Auto · retry in ${backoffMs / 1_000}s", null)
                    log.record("rfcomm_auto_retry", "delay_ms" to backoffMs)
                }
                Thread.sleep(backoffMs)
                backoffMs = (backoffMs * 2).coerceAtMost(AUTO_BACKOFF_LIMIT_MS)
            }
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        } catch (e: SecurityException) {
            if (!isStopped()) {
                onStatus("Allow Nearby devices, then restart the session.", null)
                log.record("bluetooth_permission_denied")
            }
        }
    }

    private fun connectToMac(device: BluetoothDevice): LinkOutcome {
        val timedOut = AtomicBoolean()
        val connecting = AtomicBoolean(true)
        try {
            val socket = device.createRfcommSocketToServiceRecord(ProbeProtocol.UUID)
            socket.use {
                val deadline = synchronized(lock) {
                    if (stopped) return LinkOutcome.FAILED
                    dialing = socket
                    scheduler.schedule({
                        if (connecting.compareAndSet(true, false)) {
                            timedOut.set(true)
                            socket.closeQuietly()
                        }
                    }, AUTO_CONNECT_MS, TimeUnit.MILLISECONDS)
                }
                try {
                    log.record("rfcomm_auto_connecting", "timeout_ms" to AUTO_CONNECT_MS)
                    socket.connect()
                    if (!connecting.compareAndSet(true, false)) throw IOException()
                } finally {
                    connecting.set(false)
                    deadline.cancel(false)
                }
                log.record("rfcomm_auto_open", "secure" to true)
                return serviceLink(socket)
            }
        } catch (e: IOException) {
            if (!isStopped()) {
                val reason = if (timedOut.get()) "timeout" else "socket_error"
                log.record("rfcomm_auto_connect_failed", "reason" to reason)
            }
            return LinkOutcome.FAILED
        } finally {
            synchronized(lock) { dialing = null }
        }
    }

    private fun serviceLink(socket: BluetoothSocket): LinkOutcome {
        val active = try {
            Link(socket)
        } catch (e: IOException) {
            socket.closeQuietly()
            log.record("rfcomm_link_setup_failed")
            return LinkOutcome.FAILED
        }
        active.use {
            synchronized(lock) {
                if (stopped) return LinkOutcome.FAILED
                link = active
            }
            try {
                handle(active)
                return when {
                    active.rejected -> LinkOutcome.REJECTED
                    active.authenticated -> LinkOutcome.CONNECTED
                    else -> LinkOutcome.FAILED
                }
            } finally {
                active.close()
                synchronized(lock) {
                    link = null
                    approval = null
                }
            }
        }
    }

    private fun handle(active: Link) {
        val device = active.socket.remoteDevice
        val peer = log.peerId(device.address)
        val deadlineCheck = synchronized(lock) {
            if (stopped) return
            scheduler.scheduleWithFixedDelay({
                if (SystemClock.elapsedRealtime() >= active.deadlineMs) active.close()
            }, 1, 1, TimeUnit.SECONDS)
        }
        active.startWriter()
        try {
            if (device.bondState != BluetoothDevice.BOND_BONDED) {
                log.record("rfcomm_unbonded_rejected", "peer" to peer)
                return
            }
            if (automaticPeer != null) authenticateReverse(active, device.address)
            if (active.read().type != ProbeProtocol.HELLO) throw ProbeProtocol.ProtocolError()
            active.extend(APPROVAL_MS)
            if (!authorize(active, device, peer)) return
            active.extend(IDLE_MS)
            active.write(ProbeProtocol.HELLO_ACK)
            active.authenticated = true
            onStatus(if (automaticPeer == null) "Mac connected" else "Auto · Mac connected", null)
            log.record("rfcomm_connected", "peer" to peer)
            while (!active.closed.get()) {
                val frame = active.read()
                active.extend(IDLE_MS)
                when (frame.type) {
                    ProbeProtocol.PING -> active.write(ProbeProtocol.PONG, frame.payload)
                    ProbeProtocol.CELL_PROBE -> runProbe(active) { result ->
                        if (!active.closed.get()) {
                            val detail = result.detail.toByteArray(Charsets.UTF_8)
                            val code = if (result.ok) 1.toByte() else 0.toByte()
                            try {
                                active.write(ProbeProtocol.CELL_RESULT, byteArrayOf(code) + detail)
                            } catch (e: IOException) {
                                active.close()
                            }
                        }
                    }
                    ProbeProtocol.OPEN, ProbeProtocol.DATA, ProbeProtocol.HALF_CLOSE,
                    ProbeProtocol.CLOSE, ProbeProtocol.WINDOW_UPDATE -> active.relay.handle(frame)
                    ProbeProtocol.AUTO_ENROLL -> enrollAutoKey(active, device.address, frame.payload)
                    else -> throw ProbeProtocol.ProtocolError()
                }
            }
        } catch (e: IOException) {
            val code = when {
                e is AutoAuthenticationError -> "auto_authentication_failed"
                e is ProbeProtocol.ProtocolError -> "malformed_frame"
                active.closed.get() -> "link_closed"
                e is EOFException -> "peer_eof"
                else -> "link_io"
            }
            log.record("rfcomm_ended", "peer" to peer, "reason" to code)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        } finally {
            deadlineCheck.cancel(false)
        }
    }

    private fun authenticateReverse(active: Link, address: String) {
        val key = synchronized(lock) {
            val enrolled = preferences.getString(AUTO_KEY_PEER, null)
            val encoded = preferences.getString(AUTO_KEY, null)
            if (enrolled == null && encoded == null) return
            if (enrolled != address || preferences.getString(APPROVED_PEER, null) != address ||
                encoded == null
            ) throw AutoAuthenticationError()
            try {
                Base64.getDecoder().decode(encoded)
            } catch (e: IllegalArgumentException) {
                throw AutoAuthenticationError()
            }
        }
        try {
            if (key.size != AutoAuthentication.SIZE) throw AutoAuthenticationError()
            val challenge = active.read()
            if (challenge.type != ProbeProtocol.AUTO_CHALLENGE) throw AutoAuthenticationError()
            val watchNonce = AutoAuthentication.nonce()
            val watchProof = AutoAuthentication.watchProof(key, challenge.payload, watchNonce)
            active.write(ProbeProtocol.AUTO_PROOF, watchNonce + watchProof)
            val accept = active.read()
            if (accept.type != ProbeProtocol.AUTO_ACCEPT ||
                !AutoAuthentication.acceptsMac(key, challenge.payload, watchNonce, accept.payload)
            ) throw AutoAuthenticationError()
            log.record("rfcomm_auto_authentication_passed")
        } finally {
            key.fill(0)
        }
    }

    private fun enrollAutoKey(active: Link, address: String, key: ByteArray) {
        try {
            val saved = synchronized(lock) {
                if (automaticPeer != null || stopped || link !== active || !active.connected ||
                    preferences.getString(APPROVED_PEER, null) != address
                ) throw AutoAuthenticationError()
                preferences.edit()
                    .putString(AUTO_KEY_PEER, address)
                    .putString(AUTO_KEY, Base64.getEncoder().encodeToString(key))
                    .commit()
            }
            if (!saved) {
                log.record("rfcomm_auto_enrollment_storage_failed")
                throw IOException()
            }
            active.write(ProbeProtocol.AUTO_ENROLLED)
            log.record("rfcomm_auto_enrolled")
        } finally {
            key.fill(0)
        }
    }

    private fun authorize(active: Link, device: BluetoothDevice, peer: String): Boolean {
        val address = device.address
        val pending = synchronized(lock) {
            if (stopped || link !== active) return false
            if (preferences.getString(APPROVED_PEER, null) == address) return true
            Approval(address, active.deadlineMs).also { approval = it }
        }
        onStatus("Approve this Mac?", device.name?.take(36) ?: device.address)
        log.record("peer_approval_requested", "peer" to peer)
        val answered = pending.latch.await(APPROVAL_MS, TimeUnit.MILLISECONDS)
        val allowed = synchronized(lock) {
            approval = null
            active.rejected = answered && pending.replied && !pending.accepted
            answered && !stopped && !active.closed.get() && pending.accepted &&
                preferences.getString(APPROVED_PEER, null) == address
        }
        log.record("peer_approval_finished", "peer" to peer, "allowed" to allowed)
        return allowed
    }

    fun answerApproval(allowed: Boolean) = synchronized(lock) {
        val pending = approval ?: return@synchronized
        if (pending.latch.count == 0L || stopped || SystemClock.elapsedRealtime() >= pending.deadlineMs) {
            return@synchronized
        }
        pending.replied = true
        pending.accepted = allowed
        if (allowed) {
            val editor = preferences.edit().putString(APPROVED_PEER, pending.address)
            if (preferences.getString(APPROVED_PEER, null) != pending.address) {
                editor.remove(AUTO_KEY).remove(AUTO_KEY_PEER)
            }
            editor.apply()
        }
        pending.latch.countDown()
    }

    fun forgetPeer(): Boolean = synchronized(lock) {
        val cleared = clearMacPreferences(preferences)
        approval?.latch?.countDown()
        link?.close()
        log.record(if (cleared) "peer_approval_cleared" else "peer_approval_clear_failed")
        cleared
    }

    private fun isStopped(): Boolean = synchronized(lock) { stopped }

    override fun close() = synchronized(lock) {
        if (stopped) return@synchronized
        stopped = true
        approval?.latch?.countDown()
        link?.close()
        dialing?.closeQuietly()
        listener?.closeQuietly()
        thread.interrupt()
    }

    private inner class Link(val socket: BluetoothSocket) : AutoCloseable, ProbePeer {
        val closed = AtomicBoolean()
        @Volatile var authenticated = false
        var rejected = false
        override val connected get() = authenticated && !closed.get()
        private val input = DataInputStream(BufferedInputStream(socket.inputStream))
        private val output = DataOutputStream(BufferedOutputStream(socket.outputStream))
        private val outbox = RelayOutbox()
        private val writer = Thread(::flush, "WatchRelay RFCOMM write")
        val relay = RelayLink(connectivity, log, { type, id, payload -> write(type, payload, id) }, ::close)
        @Volatile var deadlineMs = SystemClock.elapsedRealtime() + HELLO_MS
            private set

        fun extend(duration: Long) {
            deadlineMs = SystemClock.elapsedRealtime() + duration
        }

        fun startWriter() = writer.start()

        fun read(): ProbeProtocol.Frame = ProbeProtocol.read(input).also {
            received.addAndGet(ProbeProtocol.HEADER_SIZE.toLong() + it.payload.size)
        }

        fun write(type: Int, payload: ByteArray = ByteArray(0), streamId: Long = 0) {
            if (closed.get()) throw EOFException()
            if (!outbox.offer(ProbeProtocol.Frame(type, payload, streamId))) {
                log.record(
                    "rfcomm_write_queue_full",
                    "data_limit_bytes" to RelayOutbox.GLOBAL_DATA_LIMIT,
                    "control_limit" to RelayOutbox.CONTROL_LIMIT,
                )
                close()
                throw IOException()
            }
        }

        private fun flush() {
            try {
                while (!closed.get()) {
                    val frame = outbox.take() ?: return
                    ProbeProtocol.write(output, frame.type, frame.payload, frame.streamId)
                    sent.addAndGet(ProbeProtocol.HEADER_SIZE.toLong() + frame.payload.size)
                }
            } catch (e: IOException) {
                close()
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }

        override fun close() {
            if (closed.compareAndSet(false, true)) {
                socket.closeQuietly()
                outbox.close()
                log.record("rfcomm_write_queue_summary", "tx_high_water_bytes" to outbox.highWaterBytes)
                relay.close()
                cancelProbe(this)
            }
        }
    }

    private class Approval(val address: String, val deadlineMs: Long) {
        val latch = CountDownLatch(1)
        var replied = false
        var accepted = false
    }

    private enum class LinkOutcome { FAILED, CONNECTED, REJECTED }
    private class AutoAuthenticationError : IOException()

    companion object {
        const val APPROVED_PEER = "approved_laptop"
        private const val AUTO_KEY = "automatic_laptop_key"
        private const val AUTO_KEY_PEER = "automatic_laptop_key_peer"
        private const val HELLO_MS = 10_000L
        private const val APPROVAL_MS = 60_000L
        private const val IDLE_MS = 120_000L
        private const val AUTO_CONNECT_MS = 20_000L
        private const val AUTO_BACKOFF_LIMIT_MS = 30_000L
        private val CHANNEL_DESCRIPTION = Regex("""\bChannel:\s*([0-9]+)\b""")

        internal fun rfcommChannelFromDescription(description: String): Int? =
            CHANNEL_DESCRIPTION.find(description)?.groupValues?.get(1)
                ?.toIntOrNull()?.takeIf { it in 1..30 }

        internal fun clearMacPreferences(preferences: SharedPreferences): Boolean =
            preferences.edit()
                .remove(APPROVED_PEER)
                .remove(ProbeService.AUTO_PEER)
                .remove(AUTO_KEY)
                .remove(AUTO_KEY_PEER)
                .commit()
    }
}
