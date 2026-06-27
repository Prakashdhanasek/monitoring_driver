package com.example.monitoring_driver

import android.app.admin.DevicePolicyManager
import android.app.admin.WifiSsidPolicy
import android.content.ComponentName
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiSsid
import android.os.Build
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "kiosk"
    private val deviceInfoChannel = "com.proximity.driver/device_info"

    // Keep references so we can clean up the Wi-Fi request.
    private var wifiCm: ConnectivityManager? = null
    private var wifiCallback: ConnectivityManager.NetworkCallback? = null

    companion object {
        private const val WIFI_SSID = "iPhone"
        private const val WIFI_PASSWORD = "********"
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
                        try {
                            moveTaskToBack(true)
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deviceInfoChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getImei" -> {
                        try {
                            val imei = getDeviceImei()
                            if (imei != null) {
                                result.success(imei)
                            } else {
                                result.error("UNAVAILABLE", "IMEI not available", null)
                            }
                        } catch (e: Exception) {
                            result.error("ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Suppress("HardwareIds")
    private fun getDeviceImei(): String? {
        return try {
            val tm = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                tm.imei ?: tm.deviceId
            } else {
                @Suppress("DEPRECATION")
                tm.deviceId
            }
        } catch (e: SecurityException) {
            null
        } catch (e: Exception) {
            null
        }
    }

    private fun startKiosk() {
        try {
            val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            val admin = ComponentName(this, KioskAdminReceiver::class.java)

            if (dpm.isDeviceOwnerApp(packageName)) {
                dpm.setLockTaskPackages(admin, arrayOf(packageName))

                try {
                    android.provider.Settings.System.putInt(
                        contentResolver,
                        android.provider.Settings.System.SCREEN_OFF_TIMEOUT,
                        2147483647
                    )
                } catch (_: Throwable) {}

                try {
                    dpm.setMaximumTimeToLock(admin, 0)
                } catch (_: Throwable) {}

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
                        dpm.setPermissionGrantState(
                            admin, packageName,
                            "android.permission.READ_PHONE_STATE",
                            DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED
                        )
                    } catch (_: Throwable) {}
                }

                // ─────────────────────────────────────────────────────────
                // WiFi LOCK — only allow connecting to WIFI_SSID.
                // The device is blocked from joining any OTHER Wi-Fi network.
                // This is a POLICY (not a socket bind), so local cameras
                // (192.168.1.x) and the internet both stay reachable on the
                // same Wi-Fi. Requires device-owner + Android 13 (API 33)+.
                // ─────────────────────────────────────────────────────────
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    try {
                        val policy = WifiSsidPolicy(
                            WifiSsidPolicy.WIFI_SSID_POLICY_TYPE_ALLOWLIST,
                            setOf(
                                WifiSsid.fromBytes(
                                    WIFI_SSID.toByteArray(Charsets.UTF_8)
                                )
                            )
                        )
                        dpm.setWifiSsidPolicy(policy)
                    } catch (_: Throwable) {}
                }
            }

            startLockTask()
        } catch (_: Exception) {
        }

        connectToWifi()
    }

    // ───────────────────────────────────────────────
    // Just make sure Wi-Fi is ON. We do NOT bind the process to any network.
    //
    // Why no bindProcessToNetwork():
    //   Binding the app to a single Network object routed all traffic through
    //   that one network, which had no route to the local ESP32 cameras
    //   (192.168.1.x) -> "No route to host (errno 113)".
    //   The SSID LOCK above already keeps the device on the chosen Wi-Fi only,
    //   so the normal system Wi-Fi is used and BOTH the cameras and the
    //   internet are reachable.
    // ───────────────────────────────────────────────
    private fun connectToWifi() {
        try {
            val wifi = applicationContext
                .getSystemService(Context.WIFI_SERVICE) as WifiManager

            @Suppress("DEPRECATION")
            if (!wifi.isWifiEnabled) {
                @Suppress("DEPRECATION")
                wifi.isWifiEnabled = true
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val cm = applicationContext
                    .getSystemService(Context.CONNECTIVITY_SERVICE)
                        as ConnectivityManager
                wifiCm = cm

                // Release any stale callback before registering a new one.
                wifiCallback?.let {
                    try { cm.unregisterNetworkCallback(it) } catch (_: Exception) {}
                }

                val request = NetworkRequest.Builder()
                    .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                    .build()

                wifiCallback = object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        super.onAvailable(network)
                        // DO NOT bind — leave routing to the system so the
                        // local ESP32 cameras (192.168.1.x) stay reachable.
                        // cm.bindProcessToNetwork(network)  // <-- removed on purpose
                    }

                    override fun onLost(network: Network) {
                        super.onLost(network)
                        // Nothing to undo since we never bound.
                    }
                }

                cm.registerNetworkCallback(request, wifiCallback!!)
            }
        } catch (_: Exception) {
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        try {
            android.provider.Settings.System.putInt(
                contentResolver,
                android.provider.Settings.System.SCREEN_OFF_TIMEOUT,
                2147483647
            )
        } catch (_: Throwable) {}
    }

    override fun onResume() {
        super.onResume()
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun onDestroy() {
        // Clean up the Wi-Fi network callback.
        try {
            wifiCallback?.let { wifiCm?.unregisterNetworkCallback(it) }
        } catch (_: Exception) {}
        wifiCallback = null
        super.onDestroy()
    }
}