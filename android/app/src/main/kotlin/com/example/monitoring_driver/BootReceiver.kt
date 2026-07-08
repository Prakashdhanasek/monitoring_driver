package com.example.monitoring_driver

import android.app.admin.DevicePolicyManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent


class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        // Only launch on BOOT_COMPLETED (post-unlock). LOCKED_BOOT_COMPLETED
        // fires before the user unlocks — startActivity is blocked at that point.
        if (intent?.action == Intent.ACTION_BOOT_COMPLETED) {
            try {
                val bm = context.getSystemService(Context.BLUETOOTH_SERVICE)
                        as BluetoothManager
                val adapter = bm.adapter
                if (adapter != null && !adapter.isEnabled) {
                    @Suppress("DEPRECATION")
                    adapter.enable()
                }
            } catch (_: Exception) {}

            // ─────────────────────────────────────────────────────────
            // Wi-Fi auto-enable REMOVED. On boot we no longer force Wi-Fi on.
            // Instead, turn ON mobile data (device owner only). Needs a SIM +
            // data plan; may be silently blocked on some OEM / Android
            // versions, in which case the try/catch keeps boot from crashing.
            // ─────────────────────────────────────────────────────────
            try {
                val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE)
                        as DevicePolicyManager
                val admin = ComponentName(context, KioskAdminReceiver::class.java)
                if (dpm.isDeviceOwnerApp(context.packageName)) {
                    dpm.setGlobalSetting(admin, "mobile_data", "1")

                    // Register as preferred HOME so Android's HOME intent
                    // launches our app instead of the OPPO launcher on this
                    // and every subsequent reboot.
                    val homeFilter = android.content.IntentFilter(Intent.ACTION_MAIN).apply {
                        addCategory(Intent.CATEGORY_HOME)
                        addCategory(Intent.CATEGORY_DEFAULT)
                    }
                    val mainComp = ComponentName(context.packageName, "${context.packageName}.MainActivity")
                    dpm.addPersistentPreferredActivity(admin, homeFilter, mainComp)
                }
            } catch (_: Throwable) {}

            // Launch the app automatically after boot.
            try {
                val launch = Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                }
                context.startActivity(launch)
            } catch (_: Exception) {}
        }
    }
}