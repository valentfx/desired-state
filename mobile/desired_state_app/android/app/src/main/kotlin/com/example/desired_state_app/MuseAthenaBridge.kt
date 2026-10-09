package com.example.desired_state_app

import android.os.Handler
import android.os.Looper
import brainflow.BoardIds
import brainflow.BoardShim
import brainflow.BrainFlowInputParams
import brainflow.BrainFlowPresets
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** Android adapter copied from the BrainFlow-tested Athena BoardShim workflow. */
class MuseAthenaBridge(engine: FlutterEngine) : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private val worker: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
    @Volatile private var sink: EventChannel.EventSink? = null
    private var board: BoardShim? = null
    private var poll: ScheduledFuture<*>? = null
    private var started = false
    private val boardId = BoardIds.MUSE_S_ATHENA_BOARD.get_code()
    private val opticalPreset = BrainFlowPresets.ANCILLARY_PRESET
    private val motionPreset = BrainFlowPresets.AUXILIARY_PRESET

    init {
        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(this)
        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val serial = call.argument<String>("serialNumber")?.trim().orEmpty()
                        val preset = call.argument<String>("preset") ?: "p21"
                        if (preset !in listOf("p21", "p1035")) {
                            result.error("invalid_preset", "Unsupported Athena acquisition preset", null)
                            return@setMethodCallHandler
                        }
                        worker.execute {
                            try {
                                stopBoard()
                                val params = BrainFlowInputParams()
                                params.timeout = 20
                                if (serial.isNotEmpty()) params.serial_number = serial
                                // Match the independently hardware-validated Android sample.
                                params.other_info = "preset=$preset;low_latency=true"
                                val candidate = BoardShim(boardId, params)
                                board = candidate
                                candidate.prepare_session()
                                candidate.start_stream(45000)
                                started = true
                                val response = hashMapOf<String, Any>(
                                    "deviceHint" to if (serial.isEmpty()) "Muse S Athena" else serial,
                                    "eegRate" to BoardShim.get_sampling_rate(boardId),
                                    "motionRate" to BoardShim.get_sampling_rate(boardId, motionPreset),
                                    "opticalRate" to BoardShim.get_sampling_rate(boardId, opticalPreset),
                                    "eegChannels" to BoardShim.get_eeg_channels(boardId).size,
                                    "accelChannels" to BoardShim.get_accel_channels(boardId, motionPreset).size,
                                )
                                emitStatus("BrainFlow stream started; waiting for samples")
                                main.post { result.success(response) }
                                poll = worker.scheduleAtFixedRate({ drainSamples() }, 0, 250, TimeUnit.MILLISECONDS)
                            } catch (failure: Throwable) {
                                stopBoard()
                                emitStatus("Athena start failed: ${failure.message ?: failure.javaClass.simpleName}")
                                main.post {
                                    result.error("athena_start_failed", failure.message, null)
                                }
                            }
                        }
                    }
                    "stop" -> worker.execute {
                        stopBoard()
                        emitStatus("Athena stream stopped")
                        main.post { result.success(null) }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun drainSamples() {
        val active = board ?: return
        if (!started) return
        try {
            val eeg = active.get_board_data()
            val motion = active.get_board_data(motionPreset)
            val optical = active.get_board_data(opticalPreset)
            val eegIndices = BoardShim.get_eeg_channels(boardId)
            val accelIndices = BoardShim.get_accel_channels(boardId, motionPreset)
            val gyroIndices = BoardShim.get_gyro_channels(boardId, motionPreset)
            val eegTimestampRow = BoardShim.get_timestamp_channel(boardId)
            val motionTimestampRow = BoardShim.get_timestamp_channel(boardId, motionPreset)
            val opticalIndices = BoardShim.get_optical_channels(boardId, opticalPreset)
            val opticalTimestampRow = BoardShim.get_timestamp_channel(boardId, opticalPreset)
            val batteryRow = BoardShim.get_battery_channel(boardId, opticalPreset)
            val opticalCount = optical.firstOrNull()?.size ?: 0
            val eegCount = eeg.firstOrNull()?.size ?: 0
            val motionCount = motion.firstOrNull()?.size ?: 0
            if (eegCount == 0 && motionCount == 0 && opticalCount == 0) return
            val packet = hashMapOf<String, Any>(
                "type" to "samples",
                "eegCount" to eegCount,
                "motionCount" to motionCount,
                "opticalCount" to opticalCount,
                "opticalTimestamps" to optical.getOrNull(opticalTimestampRow)?.toList().orEmpty(),
                "optical" to channelRows(optical, opticalIndices, "OPT"),
                "eegTimestamps" to eeg.getOrNull(eegTimestampRow)?.toList().orEmpty(),
                "motionTimestamps" to motion.getOrNull(motionTimestampRow)?.toList().orEmpty(),
                "eeg" to channelRows(eeg, eegIndices, "EEG"),
                "accel" to channelRows(motion, accelIndices, "ACC"),
                "gyro" to channelRows(motion, gyroIndices, "GYRO"),
            )
            optical.getOrNull(batteryRow)?.lastOrNull()?.let { packet["batteryRaw"] = it }
            main.post { sink?.success(packet) }
        } catch (failure: Throwable) {
            started = false
            poll?.cancel(false)
            emitStatus("Athena stream read failed: ${failure.message ?: failure.javaClass.simpleName}")
        }
    }

    private fun channelRows(data: Array<DoubleArray>, indices: IntArray, prefix: String): Map<String, List<Double>> {
        val values = linkedMapOf<String, List<Double>>()
        indices.forEachIndexed { index, row ->
            if (row in data.indices) {
                val axis = when {
                    prefix == "ACC" || prefix == "GYRO" -> listOf("X", "Y", "Z").getOrElse(index) { "${index + 1}" }
                    else -> "${index + 1}"
                }
                values[axis] = data[row].toList()
            }
        }
        return values
    }

    private fun emitStatus(message: String) {
        val event = hashMapOf("type" to "status", "message" to message)
        main.post { sink?.success(event) }
    }

    private fun stopBoard() {
        poll?.cancel(false)
        poll = null
        val old = board
        board = null
        if (old != null) {
            try {
                if (started) old.stop_stream()
            } catch (_: Throwable) {
            } finally {
                started = false
                try {
                    old.release_session()
                } catch (_: Throwable) {
                }
            }
        } else {
            started = false
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun close() {
        worker.execute { stopBoard() }
        worker.shutdown()
    }

    companion object {
        const val METHOD_CHANNEL = "desired_state/muse_athena"
        const val EVENT_CHANNEL = "desired_state/muse_athena/stream"
    }
}
