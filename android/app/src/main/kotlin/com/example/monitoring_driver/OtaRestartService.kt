package com.example.monitoring_driver

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * Foreground service used to bring MainActivity to the foreground after an
 * OTA install. On OPPO/ColorOS (and Android 10+), starting an Activity
 * directly from a BroadcastReceiver is blocked; starting from a running
 * foreground service is allowed.
 */
class OtaRestartService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "ota_restart",
                "App Update",
                NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(channel)
        }

        @Suppress("DEPRECATION")
        val notification: Notification =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, "ota_restart")
                    .setContentTitle("Update installed — restarting…")
                    .setSmallIcon(android.R.drawable.ic_popup_sync)
                    .build()
            } else {
                Notification.Builder(this)
                    .setContentTitle("Update installed — restarting…")
                    .setSmallIcon(android.R.drawable.ic_popup_sync)
                    .build()
            }

        startForeground(9901, notification)

        // Acquire a wake lock so the screen turns on even if the device
        // was asleep when the OTA completed.
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        @Suppress("DEPRECATION")
        val wl = pm.newWakeLock(
            PowerManager.FULL_WAKE_LOCK or
            PowerManager.ACQUIRE_CAUSES_WAKEUP or
            PowerManager.ON_AFTER_RELEASE,
            "monitoring_driver:ota_restart"
        )
        wl.acquire(10_000L) // 10-second safety timeout

        // Delay 2 seconds so the system fully settles after the APK install
        // before we attempt to bring the activity to the foreground.
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            Log.i("AppInstall", "OtaRestartService: launching MainActivity to foreground")
            val launch = Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            startActivity(launch)
            if (wl.isHeld) wl.release()
            stopSelf()
        }, 2000)

        return START_NOT_STICKY
    }
}
