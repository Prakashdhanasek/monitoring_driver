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

        fun cancelAndDisable() {
            instance?.doCancelAndDisable()
        }
    }

    private var powerReceiver: BroadcastReceiver? = null
    private var shutdownHandler: Handler? = null
    private var shutdownRunnable: Runnable? = null
    private var waitingForPowerMenu = false
    private var disabled = false

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

    // Power monitoring & automatic device shutdown disabled as requested:
    // Admin exit should ONLY close the app activity without powering off the phone.
    private fun registerPowerMonitor() {
        Log.i(TAG, "Device shutdown monitor disabled — Admin Exit will close app without powering off device.")
    }

    private fun checkCurrentChargingState() {}

    private fun doCancelAndDisable() {
        Log.i(TAG, "=== CANCEL & DISABLE — admin exit ===")
        disabled = true
        waitingForPowerMenu = false
        shutdownRunnable?.let { shutdownHandler?.removeCallbacks(it) }
        shutdownHandler = null
        shutdownRunnable = null
        try { powerReceiver?.let { unregisterReceiver(it) } } catch (_: Exception) {}
        powerReceiver = null
    }

    private fun performShutdown() {
        Log.i(TAG, "performShutdown called but ignored — device shutdown disabled.")
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