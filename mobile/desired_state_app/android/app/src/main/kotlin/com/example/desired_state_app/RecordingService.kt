package com.example.desired_state_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.IBinder
import java.util.Locale

class RecordingService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        if (intent?.action == ACTION_START) {
            sessionId = intent.getStringExtra(SESSION_ID) ?: "active session"
        }
        state = intent?.getStringExtra(STATE) ?: state
        heartRate = intent?.getIntExtra(HEART_RATE, -1)?.takeIf { it >= 0 } ?: heartRate
        rmssd = intent?.getDoubleExtra(RMSSD, Double.NaN)?.takeIf { it.isFinite() } ?: rmssd
        artifactCount = intent?.getIntExtra(ARTIFACT_COUNT, artifactCount) ?: artifactCount
        elapsedSeconds = intent?.getIntExtra(ELAPSED_SECONDS, elapsedSeconds) ?: elapsedSeconds
        val notification = buildNotification()
        startForeground(NOTIFICATION_ID, notification)
        return START_NOT_STICKY
    }

    private fun buildNotification(): Notification {
        val openAppIntent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val elapsed = String.format(
            Locale.US,
            "%02d:%02d:%02d",
            elapsedSeconds / 3600,
            (elapsedSeconds % 3600) / 60,
            elapsedSeconds % 60,
        )
        val hrText = heartRate?.let { "$it bpm" } ?: "-- bpm"
        val rmssdText = rmssd?.let { String.format(Locale.US, "%.1f ms", it) } ?: "-- ms"
        val detail = if (state == "Paused") {
            "$elapsed recorded · Tap to return"
        } else {
            "HR $hrText · RMSSD $rmssdText · Artifacts $artifactCount"
        }
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("Desired State · $state · $elapsed")
            .setContentText(detail)
            .setContentIntent(pendingIntent)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .build()
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
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            },
        )
    }

    companion object {
        const val CHANNEL_ID = "desired_state_recording"
        const val NOTIFICATION_ID = 12001
        const val SESSION_ID = "sessionId"
        const val STATE = "state"
        const val HEART_RATE = "heartRate"
        const val RMSSD = "rmssd"
        const val ARTIFACT_COUNT = "artifactCount"
        const val ELAPSED_SECONDS = "elapsedSeconds"
        const val ACTION_START = "desired_state.recording.START"
        const val ACTION_UPDATE = "desired_state.recording.UPDATE"
    }

    private var sessionId = "active session"
    private var state = "Recording"
    private var heartRate: Int? = null
    private var rmssd: Double? = null
    private var artifactCount = 0
    private var elapsedSeconds = 0
}
