package com.example.monitoring_driver

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Receives android.intent.action.MY_PACKAGE_REPLACED — sent by Android to
 * the NEW version of this app immediately after it has been installed over
 * the previous version.  This is more reliable than the PackageInstaller
 * PendingIntent callback on older devices (e.g. Android 8.1 / OPPO CPH1803)
 * where the callback is sometimes not delivered.
 *
 * We simply start OtaRestartService which brings MainActivity to the screen.
 */
class PackageReplacedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        Log.i("AppInstall", "MY_PACKAGE_REPLACED received — starting OtaRestartService")
        val serviceIntent = Intent(context, OtaRestartService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }
    }
}
