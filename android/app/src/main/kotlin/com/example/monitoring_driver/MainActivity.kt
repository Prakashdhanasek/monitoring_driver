package com.example.monitoring_driver

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "kiosk"


    companion object {
        private const val WIFI_SSID = "Tommy's Phone"   // exact peru (case-sensitive)
        private const val WIFI_PASSWORD = "********"      // $ -> \$ (Kotlin safe)
    }

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
                    "connectWifi" -> {
                        connectToWifi()
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
                dpm.setLockTaskPackages(admin, arrayOf(packageName))

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    dpm.setLockTaskFeatures(
                        admin,
                        DevicePolicyManager.LOCK_TASK_FEATURE_NONE
                    )
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    try {
                        dpm.setUserControlDisabledPackages(
                            admin,
                            listOf("com.google.android.googlequicksearchbox")
                        )
                    } catch (_: Throwable) {}
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    try {
                        dpm.setPermissionGrantState(
                            admin, packageName,
                            "android.permission.BLUETOOTH_CONNECT",
                            DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED
                        )
                        dpm.setPermissionGrantState(
                            admin, packageName,
                            "android.permission.BLUETOOTH_SCAN",
                            DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED
                        )
                    } catch (_: Throwable) {}
                }
            }

            startLockTask()
        } catch (_: Exception) {
            // Lock task not available — ignore.
        }

        connectToWifi()
    }

    // ───────────────────────────────────────────────
   
    // ───────────────────────────────────────────────
    private fun connectToWifi() {
        if (WIFI_SSID == "YOUR_WIFI_NAME") return
        try {
            val wifi = applicationContext
                .getSystemService(Context.WIFI_SERVICE) as WifiManager

            @Suppress("DEPRECATION")
            if (!wifi.isWifiEnabled) {
                wifi.isWifiEnabled = true
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val specifier = WifiNetworkSpecifier.Builder()
                    .setSsid(WIFI_SSID)
                    .setWpa2Passphrase(WIFI_PASSWORD)
                    .build()

                val request = NetworkRequest.Builder()
                    .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                    .setNetworkSpecifier(specifier)
                    .build()

                val cm = applicationContext
                    .getSystemService(Context.CONNECTIVITY_SERVICE)
                        as ConnectivityManager

                cm.requestNetwork(request, object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        super.onAvailable(network)
                        // Route ALL app traffic through this WiFi.
                        cm.bindProcessToNetwork(network)
                    }
                })
            }
        } catch (_: Exception) {
            // WiFi connect fail — ignore.
        }
    }

    override fun onResume() {
        super.onResume()
        startKiosk()
    }
}