package com.example.desired_state_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.IBinder

class RecordingService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        val sessionId = intent?.getStringExtra(SESSION_ID) ?: "active session"
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("Desired State recording")
            .setContentText("Polar H10 session $sessionId is recording")
            .setOngoing(true)
            .build()
        startForeground(NOTIFICATION_ID, notification)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    private fun createChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Desired State recording",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Keeps Polar H10 session recording active while the screen is off."
            },
        )
    }

    companion object {
        const val CHANNEL_ID = "desired_state_recording"
        const val NOTIFICATION_ID = 12001
        const val SESSION_ID = "sessionId"
    }
}
