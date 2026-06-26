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
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "kiosk"
    private val deviceInfoChannel = "com.proximity.driver/device_info"


    companion object {
        private const val WIFI_SSID = "BB SF ASIANET-2.4G"   
        private const val WIFI_PASSWORD = "12345678$"      
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
                // Device-owner apps-inu ithu anuvadikkum (Android 10+ il polum).
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
            }

            startLockTask()
        } catch (_: Exception) {
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
                        cm.bindProcessToNetwork(network)
                    }
                })
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
}