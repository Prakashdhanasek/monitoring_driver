package com.example.monitoring_driver

import android.app.PendingIntent
import android.app.admin.DevicePolicyManager
import android.app.admin.WifiSsidPolicy
import android.bluetooth.BluetoothManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Build
import android.os.UserManager
import android.telephony.TelephonyManager
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "kiosk"
    private val deviceInfoChannel = "com.proximity.driver/device_info"

    // Keep references so we can clean up the Wi-Fi request.
    private var wifiCm: ConnectivityManager? = null
    private var wifiCallback: ConnectivityManager.NetworkCallback? = null

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
                        // Remove the persistent HOME preference so the system
                        // launcher takes over — without this the device relaunches
                        // this app immediately as the preferred HOME activity.
                        try {
                            val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
                            val admin = ComponentName(this, KioskAdminReceiver::class.java)
                            if (dpm.isDeviceOwnerApp(packageName)) {
                                dpm.clearPackagePersistentPreferredActivities(admin, packageName)
                            }
                        } catch (_: Exception) {}
                        result.success(true)
                        // Close the activity so the system launcher comes to front.
                        try {
                            finishAndRemoveTask()
                        } catch (_: Exception) {
                            try { finish() } catch (_: Exception) {}
                        }
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path != null) {
                            installApkSilently(path, result)
                        } else {
                            result.error("INVALID_ARGUMENT", "APK path is required", null)
                        }
                    }
                    "isDeviceOwner" -> {
                        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
                        result.success(dpm.isDeviceOwnerApp(packageName))
                    }
                    "connectWifi" -> {
                        connectToWifi()
                        result.success(true)
                    }
                    "enableMobileData" -> {
                        enableMobileData()
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
                    "scanFile" -> {
                        try {
                            val path = call.argument<String>("path")
                            if (path != null) {
                                android.media.MediaScannerConnection.scanFile(
                                    applicationContext,
                                    arrayOf(path),
                                    null
                                ) { _, _ -> }
                                result.success(true)
                            } else {
                                result.error("INVALID_ARGUMENT", "Path is null", null)
                            }
                        } catch (e: Exception) {
                            result.error("ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.monitoring_driver/settings")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openHotspotSettings" -> {
                        try {
                            // Temporarily unlock kiosk so settings can open
                            try { stopLockTask() } catch (_: Exception) {}

                            // Try direct hotspot/tethering settings first
                            val intent = Intent()
                            intent.setClassName(
                                "com.android.settings",
                                "com.android.settings.TetherSettings"
                            )
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                val intent = Intent("android.settings.TETHERING_SETTINGS")
                                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(intent)
                                result.success(true)
                            } catch (e2: Exception) {
                                try {
                                    val intent = Intent(android.provider.Settings.ACTION_WIRELESS_SETTINGS)
                                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    startActivity(intent)
                                    result.success(true)
                                } catch (e3: Exception) {
                                    result.error("ERROR", e3.message, null)
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ───────────────────────────────────────────────────────────────────────
    // Silent APK install via PackageInstaller.Session.
    // When the app is Device Owner this completes with NO user prompt.
    // When NOT Device Owner the system may show its own installer UI.
    // ───────────────────────────────────────────────────────────────────────
    private fun installApkSilently(apkPath: String, result: MethodChannel.Result) {
        try {
            val file = java.io.File(apkPath)
            if (!file.exists()) {
                result.error("FILE_NOT_FOUND", "APK not found: $apkPath", null)
                return
            }

            Log.i("AppInstall", "Starting silent install: $apkPath (${file.length()} bytes)")

            val installer = packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL
            )
            params.setAppPackageName(packageName)

            val sessionId = installer.createSession(params)
            val session   = installer.openSession(sessionId)

            file.inputStream().use { input ->
                session.openWrite("base.apk", 0, file.length()).use { output ->
                    input.copyTo(output)
                    session.fsync(output)
                }
            }

            // Use a manifest-declared receiver so Android can deliver the result
            // even after the current process is killed during APK replacement.
            val action = "com.example.monitoring_driver.INSTALL_RESULT"
            // Set ourselves as the preferred HOME activity so Android relaunches us
            // automatically after killing the process for APK replacement.
            // InstallResultReceiver clears this after success to prevent auto-boot.
            val dpmInst = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            val adminInst = ComponentName(this, KioskAdminReceiver::class.java)
            if (dpmInst.isDeviceOwnerApp(packageName)) {
                try {
                    val homeFilter = android.content.IntentFilter(Intent.ACTION_MAIN).apply {
                        addCategory(Intent.CATEGORY_HOME)
                        addCategory(Intent.CATEGORY_DEFAULT)
                    }
                    val mainComp = ComponentName(packageName, "${packageName}.MainActivity")
                    dpmInst.addPersistentPreferredActivity(adminInst, homeFilter, mainComp)
                    Log.i("AppInstall", "Set as preferred HOME for post-install relaunch")
                } catch (e: Exception) {
                    Log.e("AppInstall", "addPersistentPreferredActivity failed: ${e.message}")
                }
            }

            val callbackIntent = Intent(action).setPackage(packageName)
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val pendingIntent = PendingIntent.getBroadcast(
                applicationContext,
                sessionId,
                callbackIntent,
                flags
            )

            session.commit(pendingIntent.intentSender)
            session.close()

            Log.i("AppInstall", "Session $sessionId committed — waiting for result")
            result.success(true)
        } catch (e: Exception) {
            Log.e("AppInstall", "installApkSilently exception: ${e.message}")
            try { startKiosk() } catch (_: Exception) {}
            result.error("INSTALL_FAILED", e.message, null)
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

                // Always keep app as preferred HOME so it auto-launches on boot.
                // OPPO/ColorOS blocks BOOT_COMPLETED receivers for third-party apps,
                // but the HOME app is always started by the system on every boot.
                try {
                    val homeFilter = android.content.IntentFilter(Intent.ACTION_MAIN).apply {
                        addCategory(Intent.CATEGORY_HOME)
                        addCategory(Intent.CATEGORY_DEFAULT)
                    }
                    val mainComp = ComponentName(packageName, "${packageName}.MainActivity")
                    dpm.addPersistentPreferredActivity(admin, homeFilter, mainComp)
                } catch (_: Exception) {}

                try {
                    dpm.setGlobalSetting(
                        admin,
                        android.provider.Settings.Global.STAY_ON_WHILE_PLUGGED_IN,
                        "7"
                    )
                } catch (_: Throwable) {}

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
                // WiFi LOCK REMOVED.
                // Previously this locked the device to a single SSID
                // (setWifiSsidPolicy ALLOWLIST), which blocked every other
                // Wi-Fi network. We now CLEAR any existing policy so the phone
                // can join ANY network freely.
                // ─────────────────────────────────────────────────────────
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    try {
                        // null = no SSID restriction (removes the old lock).
                        dpm.setWifiSsidPolicy(null)
                    } catch (_: Throwable) {}
                }

                // Always register as preferred HOME so Android re-launches
                // the app after reboot without relying solely on BootReceiver.
                try {
                    val homeFilter = android.content.IntentFilter(Intent.ACTION_MAIN).apply {
                        addCategory(Intent.CATEGORY_HOME)
                        addCategory(Intent.CATEGORY_DEFAULT)
                    }
                    val mainComp = ComponentName(packageName, "${packageName}.MainActivity")
                    dpm.addPersistentPreferredActivity(admin, homeFilter, mainComp)
                } catch (_: Throwable) {}

                // Disable the lock screen so the app is visible immediately
                // after every reboot (no swipe/PIN needed).
                try {
                    dpm.setKeyguardDisabled(admin, true)
                } catch (_: Throwable) {}
            }

            startLockTask()
        } catch (_: Exception) {
        }

        // ─────────────────────────────────────────────────────────
        // On app launch: auto-enable WiFi, mobile data, Bluetooth,
        // and GPS location services.
        // ─────────────────────────────────────────────────────────
        enableWifi()
        enableMobileData()
        enableBluetooth()
        enableGps()
    }

    // ───────────────────────────────────────────────
    // Turn ON Wi-Fi (device owner only). Once enabled, Android will
    // auto-reconnect to previously saved/connected networks.
    // ───────────────────────────────────────────────
    private fun enableWifi() {
        try {
            val wifi = applicationContext
                .getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            if (!wifi.isWifiEnabled) {
                @Suppress("DEPRECATION")
                wifi.isWifiEnabled = true
                Log.i("Kiosk", "Wi-Fi enabled on startup")
            } else {
                Log.i("Kiosk", "Wi-Fi already enabled")
            }
        } catch (_: Throwable) {
        }
    }

    // ───────────────────────────────────────────────
    // Turn ON mobile data (device owner only). Uses the hidden global setting
    // key "mobile_data" (= Settings.Global.MOBILE_DATA). Needs a SIM + data
    // plan; may be silently blocked on some OEM / Android versions, in which
    // case the try/catch keeps the app from crashing.
    // ───────────────────────────────────────────────
    private fun enableMobileData() {
        try {
            val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            val admin = ComponentName(this, KioskAdminReceiver::class.java)
            if (dpm.isDeviceOwnerApp(packageName)) {
                dpm.setGlobalSetting(admin, "mobile_data", "1")
            }
        } catch (_: Throwable) {
        }
    }

    // ───────────────────────────────────────────────
    // Turn ON Bluetooth. On Android 13+ adapter.enable() is blocked for normal
    // apps, but a DEVICE OWNER can still enable it. We first clear any
    // DISALLOW_BLUETOOTH restriction, then call enable(). Runs on every app
    // launch (via startKiosk in onResume), so the alert speaker reconnects
    // automatically. Wrapped in try/catch so it never crashes the app.
    // ───────────────────────────────────────────────
    private fun enableBluetooth() {
        try {
            val bm = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
            val adapter = bm.adapter ?: return
            if (adapter.isEnabled) return

            val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            val admin = ComponentName(this, KioskAdminReceiver::class.java)

            // Device-owner path: clear any restriction that blocks Bluetooth.
            if (dpm.isDeviceOwnerApp(packageName)) {
                try {
                    dpm.clearUserRestriction(admin, UserManager.DISALLOW_BLUETOOTH)
                } catch (_: Throwable) {}
            }

            // enable() is deprecated and a no-op for normal apps on Android 13+,
            // but still works for a device owner. Safe to call on all versions.
            @Suppress("DEPRECATION")
            try {
                adapter.enable()
            } catch (_: Throwable) {}
        } catch (_: Throwable) {
        }
    }

    // ───────────────────────────────────────────────
    // Force-enable GPS / Location Services (device owner only).
    // Uses multiple approaches to ensure location is always ON.
    // ───────────────────────────────────────────────
    private fun enableGps() {
        try {
            val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            val admin = ComponentName(this, KioskAdminReceiver::class.java)
            if (dpm.isDeviceOwnerApp(packageName)) {
                // Method 1: setLocationEnabled (Android P+ / API 28+) — most reliable
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    try {
                        dpm.setLocationEnabled(admin, true)
                        Log.i("Kiosk", "Location enabled via setLocationEnabled()")
                    } catch (e: Throwable) {
                        Log.e("Kiosk", "setLocationEnabled failed: ${e.message}")
                    }
                }

                // Method 2: setSecureSetting location_mode (fallback for older devices)
                try {
                    dpm.setSecureSetting(admin, "location_mode", "3")
                    Log.i("Kiosk", "Location mode set to HIGH_ACCURACY via setSecureSetting")
                } catch (e: Throwable) {
                    Log.e("Kiosk", "setSecureSetting location_mode failed: ${e.message}")
                }

                // Method 3: Direct Settings.Secure write (another fallback)
                try {
                    android.provider.Settings.Secure.putInt(
                        contentResolver,
                        android.provider.Settings.Secure.LOCATION_MODE,
                        3 // HIGH_ACCURACY
                    )
                } catch (_: Throwable) {}

                // Grant location permissions to this app
                try {
                    dpm.setPermissionGrantState(
                        admin, packageName,
                        "android.permission.ACCESS_FINE_LOCATION",
                        DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED
                    )
                    dpm.setPermissionGrantState(
                        admin, packageName,
                        "android.permission.ACCESS_COARSE_LOCATION",
                        DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED
                    )
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        dpm.setPermissionGrantState(
                            admin, packageName,
                            "android.permission.ACCESS_BACKGROUND_LOCATION",
                            DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED
                        )
                    }
                } catch (_: Throwable) {}
            }
        } catch (_: Throwable) {
        }
    }

    // ───────────────────────────────────────────────
    // Just make sure Wi-Fi is ON. We do NOT bind the process to any network,
    // and we do NOT restrict which SSID can be used — the phone may join any
    // Wi-Fi the user selects.
    // NOTE: This is NO LONGER called on app launch. It only runs when the Dart
    // side explicitly invokes the "connectWifi" method channel.
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
                        // DO NOT bind — leave routing to the system so local
                        // devices (ESP32 cameras) stay reachable on any subnet.
                    }

                    override fun onLost(network: Network) {
                        super.onLost(network)
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
        // Re-enter lock task mode on every resume so that after an OTA install
        // (when the activity is cold-started by OtaRestartService) the screen
        // is pinned again. startLockTask() is a no-op when already locked.
        try { startKiosk() } catch (_: Exception) {}
    }

    override fun onDestroy() {
        // Clean up the Wi-Fi network callback.
        try {
            wifiCallback?.let { wifiCm?.unregisterNetworkCallback(it) }
        } catch (_: Exception) {}

        wifiCallback = null
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -999)
        val msg    = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "no message"
        android.util.Log.e("AppInstall", "=== PackageInstaller callback ===")
        android.util.Log.e("AppInstall", "  EXTRA_STATUS         : $status")
        android.util.Log.e("AppInstall", "  EXTRA_STATUS_MESSAGE : $msg")
        when (status) {
            PackageInstaller.STATUS_SUCCESS ->
                android.util.Log.e("AppInstall", "  → SUCCESS — app should restart")
            PackageInstaller.STATUS_FAILURE ->
                android.util.Log.e("AppInstall", "  → FAILURE (generic)")
            PackageInstaller.STATUS_FAILURE_ABORTED ->
                android.util.Log.e("AppInstall", "  → FAILURE_ABORTED")
            PackageInstaller.STATUS_FAILURE_BLOCKED ->
                android.util.Log.e("AppInstall", "  → FAILURE_BLOCKED")
            PackageInstaller.STATUS_FAILURE_CONFLICT ->
                android.util.Log.e("AppInstall", "  → FAILURE_CONFLICT (signature mismatch?)")
            PackageInstaller.STATUS_FAILURE_INCOMPATIBLE ->
                android.util.Log.e("AppInstall", "  → FAILURE_INCOMPATIBLE")
            PackageInstaller.STATUS_FAILURE_INVALID ->
                android.util.Log.e("AppInstall", "  → FAILURE_INVALID (bad APK?)")
            PackageInstaller.STATUS_FAILURE_STORAGE ->
                android.util.Log.e("AppInstall", "  → FAILURE_STORAGE (no space?)")
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                android.util.Log.e("AppInstall", "  → PENDING_USER_ACTION (not Device Owner?)")
                // Launch the confirmation UI if we somehow lost DO status
                val confirmIntent = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (confirmIntent != null) {
                    try { startActivity(confirmIntent) } catch (_: Exception) {}
                }
            }
            else -> android.util.Log.e("AppInstall", "  → UNKNOWN status: $status")
        }
        android.util.Log.e("AppInstall", "=================================")
    }
}