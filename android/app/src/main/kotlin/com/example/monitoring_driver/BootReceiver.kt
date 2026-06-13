package com.example.monitoring_driver

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
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
            val launch = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
            launch?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(launch)
        }
    }
}