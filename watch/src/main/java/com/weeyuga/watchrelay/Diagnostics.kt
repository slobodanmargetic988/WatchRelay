package com.weeyuga.watchrelay

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.UUID

internal class Diagnostics(context: Context) {
    private val session = UUID.randomUUID().toString()
    private val peerSalt = UUID.randomUUID().toString()
    val filename = "$session.jsonl"
    private val file = File(context.filesDir, "diagnostics/$filename")
    private var bytes = 0

    init {
        file.parentFile?.let { directory ->
            directory.mkdirs()
            directory.listFiles { candidate -> candidate.extension == "jsonl" }
                ?.sortedByDescending { it.lastModified() }
                ?.drop(3)
                ?.forEach { it.delete() }
        }
        record("session_created", "model" to Build.MODEL, "android_api" to Build.VERSION.SDK_INT)
    }

    @Synchronized
    fun record(event: String, vararg fields: Pair<String, Any?>) {
        val data = JSONObject()
            .put("build", BuildConfig.VERSION_NAME)
            .put("session", session)
            .put("wall_ms", System.currentTimeMillis())
            .put("monotonic_ms", SystemClock.elapsedRealtime())
            .put("event", event)
        fields.forEach { (key, value) -> data.put(key, value ?: JSONObject.NULL) }
        val line = (data.toString() + "\n").toByteArray(Charsets.UTF_8)
        if (line.size + bytes > 256 * 1024) return
        try {
            file.appendBytes(line)
            bytes += line.size
        } catch (e: java.io.IOException) {
            Log.w("WatchRelay", "Unable to write private diagnostics")
        }
    }

    fun peerId(address: String): String = MessageDigest.getInstance("SHA-256")
        .digest("$peerSalt:$address".toByteArray(Charsets.UTF_8))
        .take(6)
        .joinToString("") { "%02x".format(it) }

    fun sample(context: Context, rx: Long, tx: Long) {
        val power = context.getSystemService(PowerManager::class.java)
        val battery = context.getSystemService(BatteryManager::class.java)
        val percent = battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
            .takeIf { it in 0..100 }
        val plugged = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1)
            ?.takeIf { it >= 0 }
        record(
            "sample", "battery_percent" to percent, "external_power" to plugged?.let { it != 0 },
            "charging" to battery.isCharging, "interactive" to power.isInteractive,
            "thermal_status" to power.currentThermalStatus, "rfcomm_rx_bytes" to rx,
            "rfcomm_tx_bytes" to tx,
        )
    }
}
