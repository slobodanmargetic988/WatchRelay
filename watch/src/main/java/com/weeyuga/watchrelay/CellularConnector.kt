package com.weeyuga.watchrelay

import android.net.ConnectivityManager
import android.net.DnsResolver
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.CancellationSignal
import android.os.SystemClock
import android.system.ErrnoException
import android.system.OsConstants
import java.io.IOException
import java.net.ConnectException
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NoRouteToHostException
import java.net.Proxy
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

internal class RelayOpenFailure(val socksCode: Int) : IOException()

internal class CellularConnector(
    private val connectivity: ConnectivityManager,
    private val log: Diagnostics,
    private val onLost: () -> Unit,
) : AutoCloseable {
    private val lock = ReentrantLock()
    private val networkChanged = lock.newCondition()
    private val sockets = mutableSetOf<Socket>()
    private val lookups = mutableSetOf<Lookup>()
    private var registered = false
    private var closed = false
    private var selected: Network? = null
    @Volatile var networkLost = false
        private set

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
            if (!isCellular(caps)) {
                lose(network, "capabilities_changed")
                return
            }
            val previous = lock.withLock { selected }
            if (previous == network) return
            if (previous != null) lose(previous, "network_replaced")
            lock.withLock {
                if (closed) return
                selected = network
                log.record(
                    "relay_cellular_selected",
                    "transport" to "CELLULAR",
                    "validated" to caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
                )
                networkChanged.signalAll()
            }
        }

        override fun onLost(network: Network) = lose(network, "network_lost")
    }

    fun connect(destination: RelayDestination): Socket {
        val started = SystemClock.elapsedRealtime()
        try {
            val network = awaitNetwork()
            val addresses = destination.address?.let(::listOf)
                ?: resolve(network, destination.hostname ?: throw RelayOpenFailure(8))
            val first = addresses.first()
            val alternate = addresses.firstOrNull { (it is Inet4Address) != (first is Inet4Address) }
            val candidates = (listOfNotNull(first, alternate) + addresses).distinct().take(3)
            var failure = RelayOpenFailure(4)
            for (address in candidates) {
                requireCellular(network)
                try {
                    return connectAddress(network, address, destination.port).also {
                        log.record(
                            "relay_cellular_tcp_connected", "transport" to "CELLULAR",
                            "remote_dns" to (destination.address == null),
                            "elapsed_ms" to (SystemClock.elapsedRealtime() - started),
                        )
                    }
                } catch (e: IOException) {
                    requireCellular(network)
                    failure = if (e is RelayOpenFailure) e else RelayOpenFailure(socksCode(e))
                }
            }
            throw failure
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            throw RelayOpenFailure(1)
        } catch (e: SecurityException) {
            log.record("relay_cellular_tcp_failed", "socks_code" to 2, "reason" to "permission")
            throw RelayOpenFailure(2)
        } catch (e: RelayOpenFailure) {
            log.record(
                "relay_cellular_tcp_failed", "socks_code" to e.socksCode,
                "elapsed_ms" to (SystemClock.elapsedRealtime() - started),
            )
            throw e
        }
    }

    private fun awaitNetwork(): Network = lock.withLock {
        if (closed) throw RelayOpenFailure(1)
        if (!registered) {
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            try {
                connectivity.requestNetwork(request, callback)
            } catch (e: SecurityException) {
                throw e
            } catch (e: RuntimeException) {
                throw RelayOpenFailure(1)
            }
            registered = true
        }
        var remaining = TimeUnit.SECONDS.toNanos(12)
        while (!closed && selected == null && remaining > 0) {
            remaining = networkChanged.awaitNanos(remaining)
        }
        if (closed) throw RelayOpenFailure(1)
        selected ?: throw RelayOpenFailure(3)
    }

    private fun requireCellular(network: Network) {
        lock.withLock {
            if (closed) throw RelayOpenFailure(1)
            if (selected != network) throw RelayOpenFailure(3)
        }
        if (!isCellular(connectivity.getNetworkCapabilities(network))) {
            lose(network, "capabilities_unavailable")
            throw RelayOpenFailure(3)
        }
    }

    private fun resolve(network: Network, hostname: String): List<InetAddress> {
        requireCellular(network)
        val lookup = Lookup()
        lock.withLock {
            if (closed || selected != network) throw RelayOpenFailure(3)
            lookups.add(lookup)
        }
        try {
            DnsResolver.getInstance().query(
                network, hostname, DnsResolver.FLAG_EMPTY, Executor { it.run() }, lookup.signal,
                object : DnsResolver.Callback<List<InetAddress>> {
                    override fun onAnswer(answer: List<InetAddress>, rcode: Int) {
                        lookup.result.complete(if (rcode == 0) answer else emptyList())
                    }

                    override fun onError(error: DnsResolver.DnsException) {
                        lookup.result.complete(emptyList())
                    }
                },
            )
            val addresses = lookup.result.get(5, TimeUnit.SECONDS)
            requireCellular(network)
            return addresses.ifEmpty { throw RelayOpenFailure(4) }
        } catch (e: TimeoutException) {
            throw RelayOpenFailure(4)
        } catch (e: ExecutionException) {
            throw (e.cause as? RelayOpenFailure ?: RelayOpenFailure(1))
        } finally {
            lock.withLock { lookups.remove(lookup) }
            lookup.signal.cancel()
        }
    }

    private fun connectAddress(network: Network, address: InetAddress, port: Int): Socket {
        val socket = Socket(Proxy.NO_PROXY)
        var connected = false
        try {
            lock.withLock {
                if (closed || selected != network) throw RelayOpenFailure(3)
                sockets.removeAll { it.isClosed }
                sockets.add(socket)
            }
            network.bindSocket(socket)
            socket.connect(InetSocketAddress(address, port), 3_000)
            requireCellular(network)
            connected = true
            return socket
        } finally {
            if (!connected) {
                lock.withLock { sockets.remove(socket) }
                socket.closeQuietly()
            }
        }
    }

    private fun lose(network: Network, reason: String) {
        val cleanup = lock.withLock {
            if (selected != network) return
            selected = null
            networkLost = true
            collectResources()
        }
        cleanup.cancel(3)
        log.record("relay_cellular_lost", "reason" to reason)
        onLost()
    }

    override fun close() {
        val (cleanup, unregister) = lock.withLock {
            if (closed) return
            closed = true
            selected = null
            networkChanged.signalAll()
            collectResources() to registered
        }
        cleanup.cancel(1)
        if (unregister) runCatching { connectivity.unregisterNetworkCallback(callback) }
    }

    private fun collectResources(): Resources {
        val resources = Resources(sockets.toList(), lookups.toList())
        sockets.clear()
        lookups.clear()
        return resources
    }

    private class Lookup {
        val signal = CancellationSignal()
        val result = CompletableFuture<List<InetAddress>>()
    }

    private data class Resources(val sockets: List<Socket>, val lookups: List<Lookup>) {
        fun cancel(socksCode: Int) {
            sockets.forEach { it.closeQuietly() }
            lookups.forEach {
                it.result.completeExceptionally(RelayOpenFailure(socksCode))
                it.signal.cancel()
            }
        }
    }

    companion object {
        private fun isCellular(caps: NetworkCapabilities?): Boolean = caps != null &&
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) &&
            !caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
            !caps.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) &&
            !caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) &&
            !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)

        private fun socksCode(error: IOException): Int {
            val errno = generateSequence<Throwable>(error) { it.cause }
                .filterIsInstance<ErrnoException>().firstOrNull()?.errno
            return when {
                errno == OsConstants.ECONNREFUSED -> 5
                errno == OsConstants.ENETUNREACH -> 3
                errno == OsConstants.EHOSTUNREACH -> 4
                error is SocketTimeoutException || error is NoRouteToHostException -> 4
                error is ConnectException -> 5
                else -> 1
            }
        }
    }
}
