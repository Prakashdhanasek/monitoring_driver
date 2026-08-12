package com.example.monitoring_driver

import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log

// Vehicle power management: enters deep sleep when charger disconnects,
// wakes and launches app when charger connects.
class PowerConnectionReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "PowerConnectionReceiver"
        private const val SLEEP_DELAY_MS = 5_000L
        private var sleepHandler: Handler? = null
        private var sleepRunnable: Runnable? = null
    }

    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_POWER_DISCONNECTED -> {
                Log.e(TAG, "=== CHARGER DISCONNECTED — deep sleep in ${SLEEP_DELAY_MS/1000}s ===")
                val handler = Handler(Looper.getMainLooper())
                val runnable = Runnable { enterDeepSleep(context) }
                sleepHandler = handler
                sleepRunnable = runnable
                handler.postDelayed(runnable, SLEEP_DELAY_MS)
            }
            Intent.ACTION_POWER_CONNECTED -> {
                sleepRunnable?.let { sleepHandler?.removeCallbacks(it) }
                sleepHandler = null
                sleepRunnable = null
                Log.e(TAG, "=== CHARGER CONNECTED — waking up ===")
                wakeAndLaunch(context)
            }
        }
    }

    private fun enterDeepSleep(context: Context) {
        Log.e(TAG, "=== ENTERING DEEP SLEEP ===")
        try {
            val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE)
                    as DevicePolicyManager
            val admin = ComponentName(context, KioskAdminReceiver::class.java)

            if (dpm.isDeviceOwnerApp(context.packageName)) {
                // Disable stay-on-while-plugged so screen can turn off
                dpm.setGlobalSetting(admin,
                    android.provider.Settings.Global.STAY_ON_WHILE_PLUGGED_IN, "0")

                // Set screen timeout to minimum
                try {
                    android.provider.Settings.System.putInt(
                        context.contentResolver,
                        android.provider.Settings.System.SCREEN_OFF_TIMEOUT,
                        15000
                    )
                } catch (_: Throwable) {}

                // Disable WiFi to save battery
                try {
                    val wifi = context.getSystemService(Context.WIFI_SERVICE)
                            as android.net.wifi.WifiManager
                    @Suppress("DEPRECATION")
                    wifi.isWifiEnabled = false
                } catch (_: Throwable) {}

                // Disable Bluetooth to save battery
                try {
                    val bm = context.getSystemService(Context.BLUETOOTH_SERVICE)
                            as android.bluetooth.BluetoothManager
                    @Suppress("DEPRECATION")
                    bm.adapter?.disable()
                } catch (_: Throwable) {}

                // Disable GPS
                try {
                    dpm.setLocationEnabled(admin, false)
                } catch (_: Throwable) {}
            }

            // Lock the screen — turns display off, device enters Doze
            dpm.lockNow()
            Log.e(TAG, "Deep sleep active — screen off, radios off, GPS off")
        } catch (e: Exception) {
            Log.e(TAG, "Deep sleep failed: ${e.message}")
        }
    }

    @Suppress("DEPRECATION")
    private fun wakeAndLaunch(context: Context) {
        Log.e(TAG, "=== WAKING FROM DEEP SLEEP ===")
        try {
            val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE)
                    as DevicePolicyManager
            val admin = ComponentName(context, KioskAdminReceiver::class.java)

            if (dpm.isDeviceOwnerApp(context.packageName)) {
                // Restore stay-on-while-plugged
                dpm.setGlobalSetting(admin,
                    android.provider.Settings.Global.STAY_ON_WHILE_PLUGGED_IN, "7")

                // Restore screen timeout to max
                try {
                    android.provider.Settings.System.putInt(
                        context.contentResolver,
                        android.provider.Settings.System.SCREEN_OFF_TIMEOUT,
                        2147483647
                    )
                } catch (_: Throwable) {}

                // Re-enable GPS (High Accuracy Mode)
                try {
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                        dpm.setLocationEnabled(admin, true)
                    }
                    dpm.setSecureSetting(admin, "location_mode", "3")
                    dpm.setSecureSetting(admin, "location_providers_allowed", "+gps,+network")
                } catch (_: Throwable) {}
            }

            // Wake the screen
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            val wl = pm.newWakeLock(
                PowerManager.FULL_WAKE_LOCK
                        or PowerManager.ACQUIRE_CAUSES_WAKEUP
                        or PowerManager.ON_AFTER_RELEASE,
                "$TAG:wake"
            )
            wl.acquire(10_000L)

            // Launch the app (startKiosk() will re-enable WiFi, BT, etc.)
            val launch = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            }
            context.startActivity(launch)
            Log.e(TAG, "Wake complete — app launched")
        } catch (e: Exception) {
            Log.e(TAG, "Wake failed: ${e.message}")
        }
    }
}
