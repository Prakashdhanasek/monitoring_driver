package com.example.monitoring_driver

import android.app.admin.DeviceAdminReceiver
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent

/// Empty receiver — its presence (declared in the manifest) lets the app be
/// registered as a Device Owner via:
///   adb shell dpm set-device-owner <pkg>/.KioskAdminReceiver
class KioskAdminReceiver : DeviceAdminReceiver() {
    override fun onEnabled(context: Context, intent: Intent) {
        super.onEnabled(context, intent)
        try {
            val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE)
                    as DevicePolicyManager
            val admin = ComponentName(context, KioskAdminReceiver::class.java)
            if (dpm.isDeviceOwnerApp(context.packageName)) {
                dpm.setKeyguardDisabled(admin, true)
            }
        } catch (_: Exception) {}
    }
}