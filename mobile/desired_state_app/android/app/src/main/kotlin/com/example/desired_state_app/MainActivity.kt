package com.example.desired_state_app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val sessionId = call.argument<String>("sessionId")
                        if (sessionId.isNullOrBlank()) {
                            result.error("missing_session_id", "A session ID is required.", null)
                            return@setMethodCallHandler
                        }
                        val intent = Intent(this, RecordingService::class.java)
                            .putExtra(RecordingService.SESSION_ID, sessionId)
                        startForegroundService(intent)
                        result.success(null)
                    }
                    "stop" -> {
                        stopService(Intent(this, RecordingService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        const val CHANNEL = "desired_state/recording_service"
    }
}
