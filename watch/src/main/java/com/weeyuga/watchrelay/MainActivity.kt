package com.weeyuga.watchrelay

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject
import java.io.File
import kotlin.math.roundToInt

class MainActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var status: TextView
    private lateinit var statusDetail: TextView
    private lateinit var details: TextView
    private lateinit var controls: LinearLayout
    private lateinit var diagnosticsView: LinearLayout
    private lateinit var approval: TextView
    private lateinit var allow: Button
    private lateinit var deny: Button
    private lateinit var start: Button
    private lateinit var autoConnect: Button
    private lateinit var check: Button
    private lateinit var stop: Button
    private lateinit var forget: Button
    private var notice: String? = null
    private var pendingAutoPeer: String? = null
    private val preferences by lazy { getSharedPreferences(ProbeService.PREFERENCES, MODE_PRIVATE) }

    private val refresh = object : Runnable {
        override fun run() {
            render()
            handler.postDelayed(this, 500)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingAutoPeer = savedInstanceState?.getString(ProbeService.AUTO_PEER)
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(23), dp(26), dp(23), dp(34))
        }
        val scroll = ScrollView(this).apply {
            isFillViewport = true
            isVerticalScrollBarEnabled = false
            setBackgroundColor(BACKGROUND)
            addView(content)
        }
        setContentView(scroll)
        text(content, "WatchRelay", 23f, strong = true)
        controls = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }.also { content.addView(it) }
        val session = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(10), dp(6), dp(10), dp(6))
            background = rounded(SURFACE, 18)
            controls.addView(this, row(5, 6))
        }
        status = text(session, "", 15f, strong = true)
        statusDetail = text(session, "", 14f, color = MUTED)
        approval = text(controls, "", 14f, color = MUTED)
        allow = button(controls, "Approve Mac", ButtonTone.PRIMARY) { ProbeService.running?.answerApproval(true) }
        deny = button(controls, "Reject", ButtonTone.DANGER) { ProbeService.running?.answerApproval(false) }
        autoConnect = button(controls, "Auto-connect", ButtonTone.PRIMARY) { ensureConnectPermission(automatic = true) }
        start = button(controls, "Start session") { ensureConnectPermission(automatic = false) }
        check = button(controls, "Check cellular") {
            notice = null
            ProbeService.running?.checkCellular()
        }
        stop = button(controls, "Stop session", ButtonTone.DANGER) {
            notice = null
            ProbeService.running?.stopSession("Stopped")
        }
        button(controls, "Pair Mac", action = ::ensureDiscoverablePermission)
        forget = button(controls, "Forget Mac", ButtonTone.DANGER) {
            val service = ProbeService.running
            val cleared = service?.forgetPeer() ?: BluetoothProbeServer.clearMacPreferences(preferences)
            notice = if (cleared) "Mac approval cleared" else "Could not save Mac removal. Try again."
            render()
        }
        button(controls, "Diagnostics") {
            updateDiagnostics()
            controls.visibility = View.GONE
            diagnosticsView.visibility = View.VISIBLE
            scroll.scrollTo(0, 0)
        }
        diagnosticsView = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            visibility = View.GONE
        }.also { content.addView(it) }
        text(diagnosticsView, "Diagnostics", 16f, strong = true)
        details = text(diagnosticsView, "", 14f).apply {
            gravity = Gravity.START
            setLineSpacing(dp(3).toFloat(), 1f)
            setPadding(dp(8), dp(10), dp(8), dp(10))
            background = rounded(SURFACE, 18)
        }
        button(diagnosticsView, "Refresh", action = ::updateDiagnostics)
        button(diagnosticsView, "Back") {
            diagnosticsView.visibility = View.GONE
            controls.visibility = View.VISIBLE
            scroll.scrollTo(0, 0)
        }
        render()
    }

    override fun onResume() {
        super.onResume()
        handler.post(refresh)
    }

    override fun onPause() {
        handler.removeCallbacks(refresh)
        super.onPause()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString(ProbeService.AUTO_PEER, pendingAutoPeer)
    }

    private fun render() {
        val state = ProbeUi.state
        val channel = state.channel?.let { "Bluetooth channel $it" }
        if (status.text != state.bluetooth) status.text = state.bluetooth
        val detail = listOfNotNull(state.cellular, channel, notice).filter(String::isNotBlank).joinToString("\n")
        if (statusDetail.text != detail) statusDetail.text = detail
        statusDetail.visibility = if (detail.isEmpty()) View.GONE else View.VISIBLE
        start.visibility = if (state.active) View.GONE else View.VISIBLE
        autoConnect.visibility = start.visibility
        check.visibility = if (state.active) View.VISIBLE else View.GONE
        check.isEnabled = !state.checking
        stop.visibility = if (state.active) View.VISIBLE else View.GONE
        approval.text = state.approvalName.orEmpty()
        val visibility = if (state.approvalName != null) View.VISIBLE else View.GONE
        approval.visibility = visibility
        allow.visibility = visibility
        deny.visibility = visibility
        val knownPeer = preferences.contains(BluetoothProbeServer.APPROVED_PEER) ||
            preferences.contains(ProbeService.AUTO_PEER)
        forget.visibility = if (knownPeer) View.VISIBLE else View.GONE
    }

    private fun updateDiagnostics() {
        val state = ProbeUi.state
        val directory = File(filesDir, "diagnostics")
        val file = state.diagnostics?.let { File(directory, it) }
            ?: directory.listFiles { candidate -> candidate.extension == "jsonl" }
                ?.maxByOrNull { it.lastModified() }
        val events = file?.let {
            runCatching {
                it.readLines().takeLast(8).map { line ->
                    val event = JSONObject(line)
                    val code = event.optString("code").takeIf(String::isNotEmpty)
                    listOfNotNull(event.optString("event"), code).joinToString(" · ")
                }
            }.getOrDefault(emptyList())
        }.orEmpty()
        details.text = buildString {
            append("Build ${BuildConfig.VERSION_NAME}\n")
            append("API ${Build.VERSION.SDK_INT}\n\n")
            append("${state.bluetooth}\n${state.cellular}\n\n")
            state.channel?.let { append("Bluetooth channel $it\n\n") }
            append(file?.name ?: "No session log yet")
            events.forEach { append("\n$it") }
        }
    }

    private fun ensureConnectPermission(automatic: Boolean) {
        notice = null
        if (Build.VERSION.SDK_INT >= 31 && !granted(Manifest.permission.BLUETOOTH_CONNECT)) {
            val request = if (automatic) AUTO_CONNECT_PERMISSION else CONNECT_PERMISSION
            requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), request)
        } else {
            continueStart(automatic)
        }
    }

    private fun continueStart(automatic: Boolean) {
        if (automatic) selectAutoPeer() else maybeRequestNotification(null)
    }

    @SuppressLint("MissingPermission") // Called only after the Nearby devices permission check.
    private fun selectAutoPeer() {
        val peers = try {
            getSystemService(BluetoothManager::class.java)?.adapter?.bondedDevices.orEmpty().map {
                val address = it.address
                val label = it.name?.take(32)?.let { name -> "$name · ${address.takeLast(5)}" } ?: address
                PairedPeer(address, label)
            }.sortedBy { it.label }
        } catch (e: SecurityException) {
            notice = "Allow Nearby devices to start the session."
            render()
            return
        }
        if (peers.isEmpty()) {
            notice = "Pair your Mac before starting Auto-connect."
            render()
            return
        }
        val preferred = listOfNotNull(
            preferences.getString(ProbeService.AUTO_PEER, null),
            preferences.getString(BluetoothProbeServer.APPROVED_PEER, null),
        ).firstOrNull { address -> peers.any { it.address == address } }
        if (preferred != null) {
            maybeRequestNotification(preferred)
            return
        }
        AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
            .setTitle("Choose your paired Mac")
            .setItems(peers.map { it.label }.toTypedArray()) { _, index ->
                maybeRequestNotification(peers[index].address)
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun maybeRequestNotification(autoPeer: String?) {
        pendingAutoPeer = autoPeer
        if (Build.VERSION.SDK_INT >= 33 && !granted(Manifest.permission.POST_NOTIFICATIONS) &&
            !preferences.getBoolean("notification_asked", false)
        ) {
            preferences.edit().putBoolean("notification_asked", true).apply()
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_PERMISSION)
        } else {
            startSession()
        }
    }

    private fun startSession() {
        val autoPeer = pendingAutoPeer
        pendingAutoPeer = null
        notice = try {
            val intent = Intent(this, ProbeService::class.java)
            if (autoPeer != null) intent.putExtra(ProbeService.AUTO_PEER, autoPeer)
            startForegroundService(intent)
            if (autoPeer != null) preferences.edit().putString(ProbeService.AUTO_PEER, autoPeer).apply()
            null
        } catch (e: RuntimeException) {
            "Could not start the session. Open WatchRelay and try again."
        }
        render()
    }

    private fun ensureDiscoverablePermission() {
        if (Build.VERSION.SDK_INT >= 31 && !granted(Manifest.permission.BLUETOOTH_ADVERTISE)) {
            requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_ADVERTISE), DISCOVERY_PERMISSION)
        } else {
            requestDiscoverability()
        }
    }

    @Suppress("DEPRECATION") // Platform result callback keeps the probe free of UI dependencies.
    private fun requestDiscoverability() {
        notice = try {
            startActivityForResult(
                Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE)
                    .putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 120),
                DISCOVERY_RESULT,
            )
            null
        } catch (e: ActivityNotFoundException) {
            "Pairing prompt unavailable. Try the watch Bluetooth settings."
        } catch (e: SecurityException) {
            "Allow Nearby devices to pair your Mac."
        }
        render()
    }

    @Deprecated("Platform activity result callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == DISCOVERY_RESULT) {
            notice = if (resultCode > 0) "Pair in Mac Bluetooth settings now." else "Pairing mode cancelled"
            render()
        }
    }

    @Deprecated("Platform permission result callback")
    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val allowed = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        when (requestCode) {
            CONNECT_PERMISSION, AUTO_CONNECT_PERMISSION -> if (allowed) continueStart(requestCode == AUTO_CONNECT_PERMISSION)
                else { notice = "Allow Nearby devices to start the session." }
            DISCOVERY_PERMISSION -> if (allowed) requestDiscoverability()
                else { notice = "Allow Nearby devices to pair your Mac." }
            NOTIFICATION_PERMISSION -> startSession()
        }
        render()
    }

    private fun granted(permission: String): Boolean =
        checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun text(
        parent: LinearLayout, value: String, size: Float, color: Int = TEXT, strong: Boolean = false,
    ): TextView = TextView(this).apply {
        text = value
        textSize = size
        setTextColor(color)
        if (strong) typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        gravity = Gravity.CENTER
        setPadding(0, dp(3), 0, dp(3))
        parent.addView(this)
    }

    private fun button(
        parent: LinearLayout, title: String, tone: ButtonTone = ButtonTone.SECONDARY, action: () -> Unit,
    ): Button = Button(this).apply {
        text = title
        textSize = 14f
        isAllCaps = false
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        gravity = Gravity.CENTER
        minHeight = dp(48)
        minimumHeight = dp(48)
        backgroundTintList = null
        stateListAnimator = null
        val disabled = intArrayOf(-android.R.attr.state_enabled)
        background = StateListDrawable().apply {
            addState(disabled, rounded(DISABLED_FILL, 24))
            addState(intArrayOf(android.R.attr.state_pressed), rounded(tone.pressed, 24, tone.outline))
            addState(intArrayOf(android.R.attr.state_focused), rounded(tone.pressed, 24, tone.outline))
            addState(intArrayOf(), rounded(tone.fill, 24, tone.outline))
        }
        setPadding(dp(10), dp(8), dp(10), dp(8))
        setTextColor(ColorStateList(arrayOf(disabled, intArrayOf()), intArrayOf(DISABLED_TEXT, tone.label)))
        setOnClickListener { action() }
        parent.addView(this, row(3, 3))
    }

    private fun rounded(fill: Int, radius: Int, outline: Int? = null) = GradientDrawable().apply {
        setColor(fill)
        cornerRadius = dp(radius).toFloat()
        if (outline != null) setStroke(dp(1), outline)
    }

    private fun row(top: Int, bottom: Int) = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT,
    ).apply { setMargins(0, dp(top), 0, dp(bottom)) }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()

    private data class PairedPeer(val address: String, val label: String)

    private enum class ButtonTone(val fill: Int, val pressed: Int, val label: Int, val outline: Int? = null) {
        PRIMARY(0xffaef4cd.toInt(), 0xff8cdbb3.toInt(), 0xff082117.toInt()),
        SECONDARY(0xff243d36.toInt(), 0xff35584c.toInt(), 0xffecfff6.toInt(), 0xff6e9585.toInt()),
        DANGER(0xff44252b.toInt(), 0xff663840.toInt(), 0xffffced4.toInt(), 0xffba747f.toInt()),
    }

    companion object {
        private val BACKGROUND = 0xff0b1210.toInt()
        private val SURFACE = 0xff15221f.toInt()
        private val TEXT = 0xfff0faf5.toInt()
        private val MUTED = 0xffb7cdc3.toInt()
        private val DISABLED_FILL = 0xff212a27.toInt()
        private val DISABLED_TEXT = 0xffa0aba6.toInt()
        private const val CONNECT_PERMISSION = 1
        private const val DISCOVERY_PERMISSION = 2
        private const val NOTIFICATION_PERMISSION = 3
        private const val DISCOVERY_RESULT = 4
        private const val AUTO_CONNECT_PERMISSION = 5
    }
}
