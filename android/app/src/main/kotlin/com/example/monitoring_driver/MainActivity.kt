package com.example.monitoring_driver

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel


class MainActivity : FlutterActivity() {
    private val channelName = "kiosk"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startKiosk" -> {
                        startKiosk()
                        result.success(true)
                    }
                    "stopKiosk" -> {
                        try {
                            stopLockTask()
                        } catch (_: Exception) {}
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startKiosk() {
        try {
            val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            val admin = ComponentName(this, KioskAdminReceiver::class.java)

            if (dpm.isDeviceOwnerApp(packageName)) {
                // Allowlist ourselves for a true (no-exit) lock task.
                dpm.setLockTaskPackages(admin, arrayOf(packageName))

                // Block Home button, status bar / notification shade, and the
                // power-button long-press menu (Gemini/Assistant) during kiosk.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    dpm.setLockTaskFeatures(
                        admin,
                        DevicePolicyManager.LOCK_TASK_FEATURE_NONE
                    )
                }

                // Extra: stop the Assistant (Gemini) from being launched.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    try {
                        dpm.setUserControlDisabledPackages(
                            admin,
                            listOf("com.google.android.googlequicksearchbox")
                        )
                    } catch (_: Throwable) {}
                }
            

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
    try {
        dpm.setPermissionGrantState(
            admin, packageName,
            "android.permission.BLUETOOTH_CONNECT",
            DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED
        )
    } catch (_: Throwable) {}
}
            }

            startLockTask()
        } catch (_: Exception) {
            // Lock task not available — ignore.
        }
    }

    override fun onResume() {
        super.onResume()
        startKiosk()
    }
}