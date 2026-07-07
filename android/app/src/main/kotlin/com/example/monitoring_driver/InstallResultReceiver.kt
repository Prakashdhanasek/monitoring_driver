package com.example.monitoring_driver

import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log

/**
 * Manifest-declared receiver for PackageInstaller session callbacks.
 * Android can start this receiver even after the app process was killed
 * during the APK install, so we can relaunch the app on success.
 */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status  = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)

        Log.i("AppInstall", "📦 Install result: status=$status message=$message")

        when (status) {
            PackageInstaller.STATUS_SUCCESS -> {
                Log.i("AppInstall", "✅ Install SUCCESS — launching app via foreground service")

                // Set our app as preferred HOME so the system brings it to the
                // foreground (required on OPPO/ColorOS where background activity
                // launches are suppressed). BootReceiver clears this on next reboot
                // so the device does not auto-launch the app after a power cycle.
                try {
                    val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE)
                            as DevicePolicyManager
                    val admin = ComponentName(context, KioskAdminReceiver::class.java)
                    if (dpm.isDeviceOwnerApp(context.packageName)) {
                        val filter = IntentFilter(Intent.ACTION_MAIN).apply {
                            addCategory(Intent.CATEGORY_HOME)
                            addCategory(Intent.CATEGORY_DEFAULT)
                        }
                        val activity = ComponentName(context, MainActivity::class.java)
                        dpm.addPersistentPreferredActivity(admin, filter, activity)
                        Log.i("AppInstall", "Set preferred HOME activity")
                    }
                } catch (e: Exception) {
                    Log.e("AppInstall", "Failed to set preferred HOME: ${e.message}")
                }

                // Use a foreground service to start the Activity.
                // Direct startActivity() from a BroadcastReceiver is blocked by
                // OPPO/ColorOS background-launch restrictions.
                val serviceIntent = Intent(context, OtaRestartService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(serviceIntent)
                } else {
                    context.startService(serviceIntent)
                }
            }
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                // Not Device Owner — prompt user to confirm install.
                val confirmIntent = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (confirmIntent != null) {
                    confirmIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(confirmIntent)
                }
            }
            else -> {
                Log.e("AppInstall", "❌ Install FAILED: status=$status message=$message")
                // Relaunch so the app can show an error / retry.
                val launchIntent = Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                }
                context.startActivity(launchIntent)
            }
        }
    }
}
