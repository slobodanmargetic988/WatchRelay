package com.weeyuga.watchrelay

import android.net.ConnectivityManager
import android.net.DnsResolver
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.CancellationSignal
import android.os.SystemClock
import java.io.BufferedInputStream
import java.io.EOFException
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SSLException
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

internal data class ProbeResult(val ok: Boolean, val detail: String)

internal class CellularProbe(
    private val connectivity: ConnectivityManager,
    private val log: Diagnostics,
    private val peer: ProbePeer?,
    private val bluetoothConnected: () -> Boolean,
) {
    private val ready = CountDownLatch(1)
    private val resolved = CountDownLatch(1)
    private val dnsCancellation = CancellationSignal()
    private val cancellation = AtomicReference<String?>()
    private val socket = AtomicReference<Socket?>()

    @Volatile private var selected: Network? = null

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
            if (selected == network && !isCellular(caps)) {
                log.record("cellular_lost", "reason" to "capabilities_changed")
                cancel("CELLULAR_LOST")
            } else if (selected == null && cancellation.get() == null && isCellular(caps)) {
                selected = network
                log.record(
                    "cellular_selected",
                    "transport" to "CELLULAR",
                    "validated" to caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
                )
                ready.countDown()
            }
        }

        override fun onLost(network: Network) {
            if (selected == network) {
                log.record("cellular_lost", "reason" to "network_lost")
                cancel("CELLULAR_LOST")
            }
        }

        override fun onUnavailable() = cancel("CELLULAR_UNAVAILABLE")
    }

    fun cancel(reason: String = "CANCELLED") {
        if (!cancellation.compareAndSet(null, reason)) return
        ready.countDown()
        resolved.countDown()
        socket.getAndSet(null)?.closeQuietly()
        dnsCancellation.cancel()
    }

    fun run(): ProbeResult {
        val started = SystemClock.elapsedRealtime()
        var registered = false
        val trigger = if (peer == null) "watch" else "mac"
        log.record(
            "cellular_probe_started",
            "trigger" to trigger,
            "rfcomm_authenticated" to bluetoothConnected(),
        )
        try {
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            checkActive()
            connectivity.requestNetwork(request, callback, ACQUIRE_MS)
            registered = true
            ready.await(ACQUIRE_MS.toLong(), TimeUnit.MILLISECONDS)
            checkActive()
            val network = selected ?: throw ProbeFailure("CELLULAR_UNAVAILABLE")
            requireCellular(network)
            val addresses = resolve(network)
            connect(network, addresses).use { raw ->
                requireCellular(network)
                val response = fetch(raw)
                requireCellular(network)
                val connected = bluetoothConnected()
                if (peer != null && !peer.connected) throw ProbeFailure("LINK_LOST")
                val elapsed = SystemClock.elapsedRealtime() - started
                log.record(
                    "cellular_https_pass",
                    "transport" to "CELLULAR",
                    "trigger" to trigger,
                    "rfcomm_authenticated" to connected,
                    "http_status" to response.first,
                    "sampled_body_bytes" to response.second,
                    "elapsed_ms" to elapsed,
                )
                return ProbeResult(true, "Cellular HTTPS ${response.first} · ${elapsed} ms")
            }
        } catch (e: Exception) {
            val code = cancellation.get() ?: when (e) {
                is ProbeFailure -> e.code
                is SocketTimeoutException -> "HTTPS_TIMEOUT"
                is SSLException -> "TLS_FAILED"
                is SecurityException -> "CELLULAR_PERMISSION"
                is InterruptedException -> "CANCELLED"
                else -> "HTTPS_FAILED"
            }
            log.record(
                "cellular_https_fail",
                "code" to code,
                "elapsed_ms" to (SystemClock.elapsedRealtime() - started),
            )
            return ProbeResult(false, code)
        } finally {
            socket.getAndSet(null)?.closeQuietly()
            dnsCancellation.cancel()
            if (registered) {
                // Android may already have removed a timed-out network request.
                runCatching { connectivity.unregisterNetworkCallback(callback) }
            }
        }
    }

    private fun checkActive() {
        cancellation.get()?.let { throw ProbeFailure(it) }
    }

    private fun requireCellular(network: Network) {
        checkActive()
        if (!isCellular(connectivity.getNetworkCapabilities(network))) {
            throw ProbeFailure("CELLULAR_LOST")
        }
    }

    private fun resolve(network: Network): List<InetAddress> {
        val result = AtomicReference<List<InetAddress>>(emptyList())
        DnsResolver.getInstance().query(
            network, HOST, DnsResolver.FLAG_NO_CACHE_LOOKUP,
            Executor { it.run() }, dnsCancellation,
            object : DnsResolver.Callback<List<InetAddress>> {
                override fun onAnswer(answer: List<InetAddress>, rcode: Int) {
                    if (rcode == 0) result.set(answer)
                    resolved.countDown()
                }

                override fun onError(error: DnsResolver.DnsException) = resolved.countDown()
            },
        )
        if (!resolved.await(5, TimeUnit.SECONDS)) throw ProbeFailure("DNS_TIMEOUT")
        checkActive()
        return result.get().ifEmpty { throw ProbeFailure("DNS_FAILED") }
    }

    private fun connect(network: Network, addresses: List<InetAddress>): Socket {
        for (address in addresses.take(3)) {
            requireCellular(network)
            val candidate = Socket()
            socket.set(candidate)
            try {
                checkActive()
                network.bindSocket(candidate)
                candidate.connect(InetSocketAddress(address, 443), 3_000)
                return candidate
            } catch (e: IOException) {
                candidate.closeQuietly()
                socket.compareAndSet(candidate, null)
                checkActive()
            }
        }
        throw ProbeFailure("CONNECT_FAILED")
    }

    private fun fetch(raw: Socket): Pair<Int, Int> {
        val factory = SSLSocketFactory.getDefault() as SSLSocketFactory
        val tls = factory.createSocket(raw, HOST, 443, true) as SSLSocket
        tls.use {
            tls.soTimeout = 5_000
            val parameters = tls.sslParameters
            parameters.endpointIdentificationAlgorithm = "HTTPS"
            tls.sslParameters = parameters
            tls.startHandshake()

            val nonce = UUID.randomUUID()
            val request = "GET /?watchrelay=$nonce HTTP/1.1\r\n" +
                "Host: $HOST\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
            tls.outputStream.write(request.toByteArray(Charsets.US_ASCII))
            tls.outputStream.flush()

            val input = BufferedInputStream(tls.inputStream)
            val statusLine = readLine(input, 1_024)
            val status = statusLine.split(' ').getOrNull(1)?.toIntOrNull()
            if (!statusLine.startsWith("HTTP/1.") || status !in 200..299) {
                throw ProbeFailure("HTTPS_BAD_STATUS")
            }
            var remaining = 8_192
            while (true) {
                val line = readLine(input, remaining)
                if (line.isEmpty()) break
                remaining -= line.length + 2
            }
            // Read a bounded body sample so a header alone cannot pass the probe.
            val bytes = input.read(ByteArray(1024))
            if (bytes <= 0) throw ProbeFailure("HTTPS_EMPTY_BODY")
            return checkNotNull(status) to bytes
        }
    }

    private fun readLine(input: BufferedInputStream, limit: Int): String {
        val line = StringBuilder()
        repeat(limit.coerceAtLeast(0)) {
            val b = input.read()
            if (b < 0) throw EOFException()
            if (b == '\n'.code) return line.toString().removeSuffix("\r")
            line.append(b.toChar())
        }
        throw ProbeFailure("HTTPS_HEADERS_TOO_LARGE")
    }

    private class ProbeFailure(val code: String) : IOException()

    companion object {
        const val TOTAL_SECONDS = 35L
        private const val ACQUIRE_MS = 15_000
        private const val HOST = "example.com"

        private fun isCellular(caps: NetworkCapabilities?): Boolean = caps != null &&
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) &&
            !caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
            !caps.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) &&
            !caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) &&
            !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
    }
}

internal fun AutoCloseable.closeQuietly() {
    runCatching { close() }
}
