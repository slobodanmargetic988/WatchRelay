package com.weeyuga.watchrelay

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothManager
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

internal object ProbeUi {
    data class State(
        val active: Boolean = false,
        val bluetooth: String = "Stopped",
        val channel: Int? = null,
        val cellular: String = "Cellular check idle",
        val checking: Boolean = false,
        val approvalName: String? = null,
        val diagnostics: String? = null,
    )

    @Volatile var state = State()
        private set

    @Synchronized
    fun update(transform: (State) -> State) {
        state = transform(state)
    }
}

class ProbeService : Service() {
    private val timers = Executors.newScheduledThreadPool(2)
    private val cellularWorker = Executors.newSingleThreadExecutor()
    private val probeLock = Any()
    private var probe: Attempt? = null
    private lateinit var diagnostics: Diagnostics
    private var bluetooth: BluetoothProbeServer? = null
    private var autoConnect = false
    private var foreground = false
    private var stopping = false
    private val thermalListener = PowerManager.OnThermalStatusChangedListener { status ->
        if (status >= PowerManager.THERMAL_STATUS_SEVERE && running === this) {
            diagnostics.record("thermal_stop", "thermal_status" to status)
            stopSession("Stopped · watch too warm")
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (stopping) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent?.action == STOP) {
            stopSession("Stopped")
            return START_NOT_STICKY
        }
        if (running === this) return START_NOT_STICKY
        val automaticPeer = intent?.getStringExtra(AUTO_PEER)
        autoConnect = automaticPeer != null
        try {
            startForeground(
                NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
            foreground = true
        } catch (e: RuntimeException) {
            Log.w("WatchRelay", "Foreground startup failed: ${e.javaClass.simpleName}")
            val message = if (e is SecurityException) {
                "Session permission denied"
            } else {
                "Session could not start"
            }
            ProbeUi.update { it.copy(active = false, bluetooth = message) }
            stopSelf()
            return START_NOT_STICKY
        }

        diagnostics = Diagnostics(this)
        val power = getSystemService(PowerManager::class.java)
        if (power.currentThermalStatus >= PowerManager.THERMAL_STATUS_SEVERE) {
            diagnostics.record("thermal_stop", "thermal_status" to power.currentThermalStatus)
            ProbeUi.update { it.copy(diagnostics = diagnostics.filename) }
            stopSession("Stopped · watch too warm")
            return START_NOT_STICKY
        }

        running = this
        ProbeUi.update {
            ProbeUi.State(active = true, bluetooth = "Starting Bluetooth", diagnostics = diagnostics.filename)
        }
        power.addThermalStatusListener(mainExecutor, thermalListener)
        diagnostics.record(
            "session_started",
            "bluetooth_mode" to if (autoConnect) "watch_connects" else "watch_listens",
            "notification_permission" to (
                Build.VERSION.SDK_INT < 33 ||
                    checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
                ),
            "cellular_probe_timeout_s" to CellularProbe.TOTAL_SECONDS,
        )
        bluetooth = BluetoothProbeServer(
            getSystemService(BluetoothManager::class.java).adapter,
            getSharedPreferences(PREFERENCES, MODE_PRIVATE),
            diagnostics,
            timers,
            getSystemService(ConnectivityManager::class.java),
            automaticPeer,
            { status, pending ->
                ProbeUi.update {
                    if (running === this) it.copy(bluetooth = status, approvalName = pending) else it
                }
            },
            { channel ->
                ProbeUi.update { if (running === this) it.copy(channel = channel) else it }
            },
            ::checkCellular,
            ::cancelPeerProbe,
        )
        bluetooth?.start()
        timers.scheduleWithFixedDelay({
            diagnostics.sample(this, bluetooth?.rxBytes ?: 0, bluetooth?.txBytes ?: 0)
        }, 0, 30, TimeUnit.SECONDS)
        return START_NOT_STICKY
    }

    internal fun checkCellular(peer: ProbePeer? = null, result: (ProbeResult) -> Unit = {}) {
        val rejection = synchronized(probeLock) {
            if (running !== this || peer?.connected == false) return@synchronized "CANCELLED"
            if (probe != null) return@synchronized "PROBE_BUSY"
            val attempt = CellularProbe(
                getSystemService(ConnectivityManager::class.java), diagnostics, peer,
                { bluetooth?.connected == true },
            )
            probe = Attempt(peer, attempt)
            ProbeUi.update { it.copy(cellular = "Checking cellular HTTPS…", checking = true) }
            val deadline = timers.schedule(
                { attempt.cancel("PROBE_TIMEOUT") }, CellularProbe.TOTAL_SECONDS, TimeUnit.SECONDS,
            )
            cellularWorker.execute {
                val outcome = attempt.run()
                deadline.cancel(false)
                synchronized(probeLock) {
                    probe = null
                    if (running === this) {
                        val detail = when (outcome.detail) {
                            "CELLULAR_UNAVAILABLE" -> "No cellular network. Check Mobile networks and your plan."
                            "CELLULAR_LOST" -> "Cellular network lost"
                            "LINK_LOST" -> "Mac link lost during check"
                            "PROBE_TIMEOUT" -> "Cellular check timed out"
                            else -> outcome.detail
                        }
                        ProbeUi.update { it.copy(cellular = detail, checking = false) }
                    }
                }
                result(outcome)
            }
            null
        }
        if (rejection != null) result(ProbeResult(false, rejection))
    }

    private fun cancelPeerProbe(peer: ProbePeer) {
        synchronized(probeLock) {
            probe?.takeIf { it.peer === peer }?.check?.cancel("LINK_LOST")
        }
    }

    internal fun answerApproval(allowed: Boolean) = bluetooth?.answerApproval(allowed)
    internal fun forgetPeer(): Boolean {
        val cleared = bluetooth?.forgetPeer()
            ?: BluetoothProbeServer.clearMacPreferences(getSharedPreferences(PREFERENCES, MODE_PRIVATE))
        if (autoConnect) stopSession("Stopped")
        return cleared
    }

    internal fun stopSession(reason: String) {
        stopResources(reason)
        stopSelf()
    }

    private fun stopResources(reason: String) {
        stopping = true
        val wasRunning = running === this
        if (wasRunning) {
            running = null
            getSystemService(PowerManager::class.java).removeThermalStatusListener(thermalListener)
        }
        // Closing Bluetooth first makes pending response writes fail immediately.
        bluetooth?.close()
        synchronized(probeLock) { probe?.check?.cancel() }
        timers.shutdownNow()
        cellularWorker.shutdownNow()
        if (foreground) {
            if (wasRunning) {
                diagnostics.sample(this, bluetooth?.rxBytes ?: 0, bluetooth?.txBytes ?: 0)
                diagnostics.record("session_stopped", "thermal_stop" to reason.contains("warm"))
            }
            stopForeground(STOP_FOREGROUND_REMOVE)
            foreground = false
        }
        if (wasRunning || reason != "Stopped") {
            ProbeUi.update {
                it.copy(
                    active = false,
                    bluetooth = reason,
                    channel = null,
                    cellular = if (it.checking) "Cellular check cancelled" else it.cellular,
                    checking = false,
                    approvalName = null,
                )
            }
        }
    }

    override fun onDestroy() {
        stopResources("Stopped")
        super.onDestroy()
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "WatchRelay sessions", NotificationManager.IMPORTANCE_LOW),
        )
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, ProbeService::class.java).setAction(STOP), PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_relay)
            .setContentTitle("WatchRelay")
            .setContentText("Watch probe active")
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
    }

    private data class Attempt(val peer: ProbePeer?, val check: CellularProbe)

    companion object {
        @Volatile internal var running: ProbeService? = null
            private set
        internal const val PREFERENCES = "watchrelay"
        internal const val AUTO_PEER = "automatic_laptop"
        private const val STOP = "com.weeyuga.watchrelay.STOP"
        private const val CHANNEL = "watchrelay.session"
        private const val NOTIFICATION_ID = 1
    }
}
