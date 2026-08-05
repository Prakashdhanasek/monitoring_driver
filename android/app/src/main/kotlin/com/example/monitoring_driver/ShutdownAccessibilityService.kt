package com.example.monitoring_driver

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

// Self-contained shutdown service: monitors charger state directly and
// powers off the device when charger is disconnected (vehicle OFF).
class ShutdownAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "ShutdownA11y"
        private const val SHUTDOWN_DELAY_MS = 8_000L
        var instance: ShutdownAccessibilityService? = null
            private set

        fun triggerShutdown() {
            instance?.performShutdown() ?: Log.e(TAG, "No instance")
        }
    }

    private var powerReceiver: BroadcastReceiver? = null
    private var shutdownHandler: Handler? = null
    private var shutdownRunnable: Runnable? = null
    private var waitingForPowerMenu = false

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        serviceInfo = AccessibilityServiceInfo().apply {
            eventTypes = AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
                    AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED
            feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            flags = AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS or
                    AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            notificationTimeout = 100
        }
        Log.e(TAG, "=== SERVICE CONNECTED — registering power monitor ===")
        registerPowerMonitor()
    }

    override fun onDestroy() {
        instance = null
        try { powerReceiver?.let { unregisterReceiver(it) } } catch (_: Exception) {}
        powerReceiver = null
        super.onDestroy()
    }

    override fun onInterrupt() {}

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (waitingForPowerMenu && event != null) {
            val source = event.source ?: return
            if (findAndClickPowerOff(source)) {
                waitingForPowerMenu = false
            }
            source.recycle()
        }
    }

    // Register our own charger disconnect listener — independent of main app
    private fun registerPowerMonitor() {
        if (powerReceiver != null) return
        powerReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    Intent.ACTION_POWER_DISCONNECTED -> {
                        Log.e(TAG, "=== CHARGER DISCONNECTED — shutdown in ${SHUTDOWN_DELAY_MS/1000}s ===")
                        val handler = Handler(Looper.getMainLooper())
                        val runnable = Runnable { performShutdown() }
                        shutdownHandler = handler
                        shutdownRunnable = runnable
                        handler.postDelayed(runnable, SHUTDOWN_DELAY_MS)
                    }
                    Intent.ACTION_POWER_CONNECTED -> {
                        Log.e(TAG, "=== CHARGER CONNECTED — cancelling shutdown ===")
                        shutdownRunnable?.let { shutdownHandler?.removeCallbacks(it) }
                        shutdownHandler = null
                        shutdownRunnable = null
                    }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_POWER_DISCONNECTED)
            addAction(Intent.ACTION_POWER_CONNECTED)
        }
        registerReceiver(powerReceiver, filter)
        Log.e(TAG, "Power monitor registered")

        // Also check current state — if already not charging, schedule shutdown
        checkCurrentChargingState()
    }

    private fun checkCurrentChargingState() {
        try {
            val batteryStatus = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val plugged = batteryStatus?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1) ?: -1
            if (plugged == 0) {
                Log.e(TAG, "=== NOT CHARGING on service start — shutdown in ${SHUTDOWN_DELAY_MS/1000}s ===")
                val handler = Handler(Looper.getMainLooper())
                val runnable = Runnable { performShutdown() }
                shutdownHandler = handler
                shutdownRunnable = runnable
                handler.postDelayed(runnable, SHUTDOWN_DELAY_MS)
            } else {
                Log.e(TAG, "Currently charging (plugged=$plugged) — standing by")
            }
        } catch (_: Throwable) {}
    }

    private fun performShutdown() {
        Log.e(TAG, "=== PERFORMING SHUTDOWN — opening power dialog ===")
        waitingForPowerMenu = true
        val success = performGlobalAction(GLOBAL_ACTION_POWER_DIALOG)
        Log.e(TAG, "Power dialog result: $success")

        Handler(Looper.getMainLooper()).postDelayed({ if (waitingForPowerMenu) tryClickPowerOff() }, 1500)
        Handler(Looper.getMainLooper()).postDelayed({ if (waitingForPowerMenu) tryClickPowerOff() }, 3000)
        Handler(Looper.getMainLooper()).postDelayed({ if (waitingForPowerMenu) tryClickPowerOff() }, 5000)
    }

    private fun tryClickPowerOff() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return
        for (window in windows) {
            val root = window.root ?: continue
            if (findAndClickPowerOff(root)) {
                waitingForPowerMenu = false
                return
            }
        }
        Log.e(TAG, "Could not find power off button — dumping UI tree")
        dumpWindowContents()
    }

    private fun findAndClickPowerOff(root: AccessibilityNodeInfo): Boolean {
        val powerOffTexts = listOf(
            "Power off", "power off", "Power Off", "POWER OFF",
            "Shut down", "shut down", "Shutdown", "shutdown", "SHUT DOWN",
            "Switch off", "switch off",
            "Turn off", "turn off",
            "बंद करें", "पावर ऑफ",
            "ഓഫ്", "പവർ ഓഫ്",
            "关机", "關機",
        )

        for (text in powerOffTexts) {
            val nodes = root.findAccessibilityNodeInfosByText(text)
            for (node in nodes) {
                if (node.isClickable) {
                    node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    Log.e(TAG, "Clicked: '$text'")
                    Handler(Looper.getMainLooper()).postDelayed({ confirmShutdown() }, 1500)
                    return true
                }
                val parent = node.parent
                if (parent != null && parent.isClickable) {
                    parent.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    Log.e(TAG, "Clicked parent of: '$text'")
                    Handler(Looper.getMainLooper()).postDelayed({ confirmShutdown() }, 1500)
                    return true
                }
            }
        }
        return false
    }

    private fun confirmShutdown() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return
        val confirmTexts = listOf("OK", "ok", "Power off", "Shut down", "Turn off", "确定", "ശരി")
        for (window in windows) {
            val root = window.root ?: continue
            for (text in confirmTexts) {
                val nodes = root.findAccessibilityNodeInfosByText(text)
                for (node in nodes) {
                    if (node.isClickable) {
                        node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                        Log.e(TAG, "Confirmed: '$text'")
                        return
                    }
                    val parent = node.parent
                    if (parent != null && parent.isClickable) {
                        parent.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                        return
                    }
                }
            }
        }
    }

    // Dump all visible UI text to logcat for debugging button labels
    private fun dumpWindowContents() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return
        for (window in windows) {
            val root = window.root ?: continue
            dumpNode(root, 0)
        }
    }

    private fun dumpNode(node: AccessibilityNodeInfo, depth: Int) {
        val indent = "  ".repeat(depth)
        val text = node.text?.toString() ?: ""
        val desc = node.contentDescription?.toString() ?: ""
        val cls = node.className?.toString() ?: ""
        if (text.isNotEmpty() || desc.isNotEmpty()) {
            Log.e(TAG, "${indent}[$cls] text='$text' desc='$desc' clickable=${node.isClickable}")
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            dumpNode(child, depth + 1)
        }
    }
}
