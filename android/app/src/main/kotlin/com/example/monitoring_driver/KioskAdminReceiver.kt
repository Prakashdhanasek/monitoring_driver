package com.example.monitoring_driver   // <-- CHANGE to your applicationId

import android.app.admin.DeviceAdminReceiver

/// Empty receiver — its presence (declared in the manifest) lets the app be
/// registered as a Device Owner via:
///   adb shell dpm set-device-owner <pkg>/.KioskAdminReceiver
class KioskAdminReceiver : DeviceAdminReceiver()