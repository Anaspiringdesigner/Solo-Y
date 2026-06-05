package com.example.biofeedback_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannel()
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            "biofeedback_data_transfer",
            "Biofeedback Data Transfer",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Transfers biometric data in background"
        }
        val manager = getSystemService(
            NotificationManager::class.java)
        manager.createNotificationChannel(channel)
    }
}