import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'polar_h10_service.dart';
import 'h10_accelerometer.dart';
import 'h10_ecg.dart';
import 'o2_ring_service.dart';
import 'device_models.dart';
import 'recording_foreground_service.dart';
import 'rr_history.dart';
import 'session_logger.dart';
import 'quick_markers.dart';
import 'processing.dart';
import 'muse_athena_service.dart';
import 'session_history.dart';
import 'participant_tools.dart';
import 'practice_controller.dart';
import 'eeg_bands.dart';

enum RecordingState { stopped, recording, paused }

class TimelinePoint {
  const TimelinePoint(this.timestamp, this.heartRate, this.rmssd, this.segment);
  final DateTime timestamp;
  final int heartRate;
  final double? rmssd;
  final int segment;
}

/// App-owned acquisition and session state. Screens only subscribe to updates.
/// Recovery never opens a logger or changes a participant assignment.
class SessionController extends ChangeNotifier {
  SessionController({
    PolarH10Service? service,
    O2RingService? ringService,
    MuseAthenaService? museService,
    RecordingForegroundService? foregroundService,
    this.directoryProvider,
    this.staleAfter = const Duration(seconds: 10),
    this.retryDelay = const Duration(seconds: 2),
    this.maxAttempts = 3,
    this.elapsedClock,
    Duration tickInterval = const Duration(seconds: 1),
  }) : polar = service ?? PolarH10Service(),
       ring = ringService ?? O2RingService(),
       museAthena = museService ?? MuseAthenaService(),
       quickMarkers = QuickMarkerStore(directoryProvider: directoryProvider),
       processing = ProcessingStore(directoryProvider: directoryProvider),
       _foreground = foregroundService ?? RecordingForegroundService() {
    practice = PracticeController(
      onEvent: (event, values) =>
          _event(event, description: jsonEncode(values)),
    );
    assert(maxAttempts > 0 && staleAfter > Duration.zero);
    _ringReadingSubscription = ring.readings.listen(_onRingReading);
    museAthena.addListener(_onMuseChanged);
    _museBatchSubscription = museAthena.batches.listen((batch) {
      final logger = sessionLogger;
      if (_recording && logger != null) {
        recordedEegSamples += (batch['eegCount'] as num?)?.toInt() ?? 0;
        _save(
          logger.logMuseBatch({
            ...batch,
            'device_hint': museAthena.deviceHint,
            'eeg_rate_hz': museAthena.eegRate,
            'motion_rate_hz': museAthena.motionRate,
            'recording_segment': _segment,
          }),
        );
      }
    });
    _ringPacketSubscription = ring.packets.listen((packet) {
      final logger = sessionLogger;
      if (_recording && logger != null && ringId != null) {
        _save(logger.logO2RingPacket(deviceId: ringId!, packet: packet));
      }
    });
    _ringStatusSubscription = ring.statusStream.listen((status) {
      ringStatus = status;
      if (status == DeviceConnectionStatus.disconnected ||
          status == DeviceConnectionStatus.error) {
        latestRingReading = null;
        _event('o2ring_disconnected', description: ringId);
      }
      _changed();
    });
    _accSubscription = polar.accelerationStream.listen((frame) {
      if (_disposed) return;
      latestAcceleration = frame;
      final previous = _lastAccTimestamp;
      if (previous != null &&
          (frame.sensorNanoseconds <= previous ||
              frame.sensorNanoseconds - previous > BigInt.from(2000000000))) {
        _accSegment++;
        _event('accelerometer_clock_gap_or_reset');
      }
      _lastAccTimestamp = frame.sensorNanoseconds;
      final logger = sessionLogger;
      if (_recording && logger != null && polarId != null) {
        recordedAccSamples += frame.samples.length;
        _save(
          logger.logAcceleration(
            deviceId: polarId!,
            frame: frame,
            segment: _accSegment,
          ),
        );
      }
      _changed();
    });
    _ecgSubscription = polar.ecgStream.listen((frame) {
      if (_disposed) return;
      final previous = _lastEcgTimestamp;
      final duration = BigInt.from(
        (frame.samples.length * 1000000000 / frame.sampleRate).round(),
      );
      if (previous == null ||
          frame.sensorNanoseconds <= previous ||
          frame.sensorNanoseconds - previous >
              duration + BigInt.from(100000000)) {
        _ecgSegment++;
        ecgPreview.clear();
      }
      _lastEcgTimestamp = frame.sensorNanoseconds;
      latestEcg = frame;
      for (var i = 0; i < frame.samples.length; i++) {
        final ns =
            frame.sensorNanoseconds -
            BigInt.from(
              ((frame.samples.length - 1 - i) * 1000000000 / frame.sampleRate)
                  .round(),
            );
        ecgPreview.add((ns, frame.samples[i].toDouble()));
      }
      while (ecgPreview.length > frame.sampleRate * 10) {
        ecgPreview.removeAt(0);
      }
      final logger = sessionLogger;
      final since = _ecgRecordingSince;
      if (_recording &&
          logger != null &&
          polarId != null &&
          since != null &&
          frame.receivedAt.toUtc().difference(since).inMicroseconds >=
              frame.samples.length * 1000000 / frame.sampleRate) {
        recordedEcgSamples += frame.samples.length;
        _save(
          logger.logEcg(deviceId: polarId!, frame: frame, segment: _ecgSegment),
        );
      }
      _changed();
    });
    _ecgStatusSubscription = polar.ecgStatusStream.listen((value) {
      ecgStatus = value;
      if (value == 'Not connected' || value == 'Disconnected') {
        latestEcg = null;
        _lastEcgTimestamp = null;
        ecgPreview.clear();
        _ecgSegment++;
      }
      _event('ecg_status', description: value);
      _changed();
    });
    _pmdSubscription = polar.pmdPackets.listen((packet) {
      final logger = sessionLogger;
      if (_recording && logger != null && polarId != null) {
        _save(logger.logPmdPacket(deviceId: polarId!, packet: packet));
      }
    });
    _accStatusSubscription = polar.accelerationStatusStream.listen((status) {
      accelerationStatus = status;
      if (status == 'Disconnected' || status == 'Not connected') {
        latestAcceleration = null;
        _lastAccTimestamp = null;
        _accSegment++;
      }
      _changed();
    });
    _dataSubscription = polar.dataStream.listen(_onData);
    _connectionSubscription = polar.connectionStream.listen((connected) {
      if (!connected) _lostConnection();
    });
    _timer = Timer.periodic(tickInterval, (_) => _tick());
  }

  late final StreamSubscription<H10Acceleration> _accSubscription;
  late final StreamSubscription<RawBlePacket> _pmdSubscription;
  late final StreamSubscription<String> _accStatusSubscription;
  late final StreamSubscription<H10EcgFrame> _ecgSubscription;
  late final StreamSubscription<String> _ecgStatusSubscription;
  H10EcgFrame? latestEcg;
  final List<(BigInt, double)> ecgPreview = [];
  String ecgStatus = 'Not connected';
  int recordedEcgSamples = 0, _ecgSegment = 0;
  BigInt? _lastEcgTimestamp;
  DateTime? _ecgRecordingSince;
  bool get ecgFresh =>
      connected &&
      latestEcg != null &&
      DateTime.now().difference(latestEcg!.receivedAt) <
          const Duration(seconds: 3);
  H10Acceleration? latestAcceleration;
  String accelerationStatus = 'Not connected';
  int recordedAccSamples = 0;
  int _accSegment = 0;
  BigInt? _lastAccTimestamp;
  final PolarH10Service polar;
  final O2RingService ring;
  final MuseAthenaService museAthena;
  late final StreamSubscription<O2RingReading> _ringReadingSubscription;
  late final StreamSubscription<RawBlePacket> _ringPacketSubscription;
  late final StreamSubscription<DeviceConnectionStatus> _ringStatusSubscription;
  DeviceConnectionStatus ringStatus = DeviceConnectionStatus.disconnected;
  BluetoothDevice? _ringTarget;
  BluetoothDevice? get ringDevice => _ringTarget;
  String? ringId;
  String ringName = 'O2Ring';
  O2RingReading? latestRingReading;
  int recordedRingReadings = 0;
  Duration? _lastRingData;
  Duration _lastRingAttempt = Duration.zero;
  bool _ringConnectInFlight = false;
  bool _ringManualDisconnect = false;
  bool get ringConnected => ringStatus == DeviceConnectionStatus.connected;
  bool get canStart => connected || ringDataFresh || museAthena.fresh;
  Duration? get ringDataAge =>
      _lastRingData == null ? null : _now - _lastRingData!;
  bool get ringDataFresh =>
      ringConnected &&
      ringDataAge != null &&
      ringDataAge! < const Duration(seconds: 10);

  void _onRingReading(O2RingReading reading) {
    if (_disposed) return;
    latestRingReading = reading;
    _lastRingData = _now;
    final logger = sessionLogger;
    if (_recording && logger != null && ringId != null) {
      recordedRingReadings++;
      _save(
        logger.logO2RingReading(
          deviceId: ringId!,
          deviceName: ringName,
          reading: reading,
        ),
      );
    }
    _changed();
  }

  Future<void> connectRing(BluetoothDevice device) async {
    if (_ringConnectInFlight || _disposed) return;
    if (sessionLogger != null &&
        ringId != null &&
        device.remoteId.str != ringId) {
      throw StateError('Stop the session before changing the assigned O2Ring.');
    }
    _ringTarget = device;
    ringId = device.remoteId.str;
    ringName = device.platformName.isEmpty ? 'O2Ring' : device.platformName;
    _ringManualDisconnect = false;
    _ringConnectInFlight = true;
    latestRingReading = null;
    _lastRingData = null;
    _lastRingAttempt = _now;
    _changed();
    try {
      await ring.connect(device);
      _event('o2ring_connected', description: ringId);
    } finally {
      _ringConnectInFlight = false;
      _changed();
    }
  }

  Future<void> disconnectRing() async {
    if (_ringConnectInFlight) return;
    _ringManualDisconnect = true;
    _event('o2ring_manual_disconnect', description: ringId);
    await ring.disconnect();
  }

  late final PracticeController practice;
  final QuickMarkerStore quickMarkers;
  final ProcessingStore processing;
  final List<RrInput> analysisInputs = [];

  Future<void> saveProcessing(ProcessingConfig config) async {
    await processing.save(config);
    final logger = sessionLogger;
    if (logger != null) {
      await logger.writeEvent(
        'processing_configuration_changed',
        description: jsonEncode(config.toJson()),
        flush: true,
      );
    }
    _changed();
  }

  final List<RecordedMarker> recordedMarkers = [];
  final Map<String, List<String>> markerNotes = {};
  final RecordingForegroundService _foreground;
  final Future<Directory> Function()? directoryProvider;
  final Duration staleAfter;
  final Duration retryDelay;
  final int maxAttempts;
  final Duration Function()? elapsedClock;
  final Stopwatch _clock = Stopwatch()..start();
  Duration get _now => elapsedClock?.call() ?? _clock.elapsed;
  late final StreamSubscription<PolarHeartRateData> _dataSubscription;
  late final StreamSubscription<bool> _connectionSubscription;
  late final Timer _timer;
  final RrHistory rrHistory = RrHistory();
  final List<TimelinePoint> timeline = [];
  final List<DateTime> eventTimes = [];
  RecordingState recordingState = RecordingState.stopped;
  SessionLogger? sessionLogger;
  SessionLogger? lastSessionLogger;
  String? _visibleSessionId;
  DateTime? sessionStartedAt;
  BluetoothDevice? _target;
  String deviceName = 'No H10 connected';
  String? polarId;
  String participant = 'unassigned';
  String status = 'Ready';
  String connectionStatus = 'Disconnected';
  String? error;
  bool connected = false;
  bool connecting = false;
  bool busy = false;
  bool recovering = false;
  bool _exhausted = false;
  bool _manualDisconnect = false;
  bool _disposed = false;
  bool _gap = false;
  int _segment = 0;
  int _epoch = 0;
  int? heartRate;
  double? latestRr;
  double? rmssd;
  Duration? _lastData;
  Duration _waitingSince = Duration.zero;
  Duration _lastNotification = Duration.zero;
  Completer<void>? _firstData;
  Timer? _retryTimer;
  Completer<void>? _retryWait;

  Duration? get lastDataAge => _lastData == null ? null : _now - _lastData!;
  Duration get sessionElapsed => sessionStartedAt == null
      ? Duration.zero
      : DateTime.now().difference(sessionStartedAt!);
  bool get _recording => recordingState == RecordingState.recording;
  bool get canReconnect => sessionLogger != null && !busy && !recovering;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  late final StreamSubscription<Map<String, dynamic>> _museBatchSubscription;
  int recordedEegSamples = 0;
  bool _museWasStreaming = false;
  DateTime? _lastRecordedBand;
  DateTime? _eegRecordingSince;
  String participantInfo = '';
  String? participantId;
  Future<void> editRecordingParticipant(
    String name,
    String info, {
    String? profileId,
  }) async {
    final logger = sessionLogger;
    if (logger == null || busy) throw StateError('No active session available');
    busy = true;
    _changed();
    try {
      // The owning controller is the only active-session annotation writer.
      final store = ParticipantStore(directoryProvider: directoryProvider);
      final profile = await store.resolve(name, info, id: profileId);
      final repository = SessionHistoryRepository(
        directoryProvider: directoryProvider,
      );
      await logger.writeEvent('participant_edit_requested', flush: true);
      final entry = await repository.readEntry(logger.directory);
      await repository.saveMetadata(
        entry,
        participantMetadata(
          entry.metadata,
          name,
          info,
          participantId: profile.id,
        ),
      );
      participant = name.trim().isEmpty ? 'unassigned' : name.trim();
      participantInfo = info.trim();
      participantId = profile.id;
      await logger.writeEvent(
        'participant_label_corrected',
        description: jsonEncode({
          'display_name': participant,
          'participant_id': participantId,
          'scope': 'whole_session',
          'original_name': logger.participantName,
        }),
        flush: true,
      );
    } finally {
      busy = false;
      _changed();
    }
  }

  void _onMuseChanged() {
    final frame = museAthena.latestBands;
    final logger = sessionLogger;
    if (_recording &&
        logger != null &&
        frame != null &&
        frame.time != _lastRecordedBand &&
        _eegRecordingSince != null &&
        museAthena.eegRate > 0 &&
        frame.time.difference(_eegRecordingSince!).inMilliseconds >=
            1024 * 1000 / museAthena.eegRate) {
      _lastRecordedBand = frame.time;
      _save(
        logger.logEegBands({
          'received_utc': frame.time.toIso8601String(),
          'channels': frame.channels,
          'usable_channels': frame.channels.length,
          'total_channels': frame.channelCount,
          'sample_rate_hz': museAthena.eegRate,
          'continuity_segment': museAthena.continuity,
          'recording_segment': _segment,
        }),
      );
    }
    if (museAthena.streaming != _museWasStreaming) {
      _museWasStreaming = museAthena.streaming;
      _event(
        _museWasStreaming ? 'muse_connected' : 'muse_disconnected',
        description: museAthena.deviceHint,
      );
    }
    _changed();
  }

  void _save(Future<void> operation) {
    unawaited(
      operation.catchError((Object failure) {
        error = 'Session/service error: $failure';
        _changed();
      }),
    );
  }

  void _event(String event, {String? description}) {
    final logger = sessionLogger;
    if (logger != null) {
      _save(logger.writeEvent(event, description: description));
    }
  }

  Future<void> connect(BluetoothDevice device) async {
    if (sessionLogger != null || connecting || busy) return;
    final epoch = ++_epoch;
    _target = device;
    _lastData = null;
    _manualDisconnect = false;
    connecting = true;
    status = connectionStatus = 'Connecting';
    _changed();
    try {
      await polar.connect(device);
      if (epoch != _epoch || _disposed) return;
      connected = true;
      final name = device.platformName.trim();
      deviceName = name.isEmpty ? device.remoteId.str : name;
      polarId =
          (RegExp(r'([A-Za-z0-9]{8})$').firstMatch(deviceName)?.group(1) ??
                  device.remoteId.str)
              .toUpperCase();
      _waitingSince = _now;
      connectionStatus = 'Connected, waiting for data';
      status = 'Connected — ready to record';
    } catch (failure) {
      if (epoch != _epoch || _disposed) return;
      connected = false;
      status = connectionStatus = 'Connection failed: $failure';
      await polar.disconnect();
    } finally {
      if (epoch == _epoch) connecting = false;
      _changed();
    }
  }

  Future<void> start({
    required String participantName,
    String? participantProfileId,
    String description = '',
  }) async {
    if (!canStart || sessionLogger != null || busy) return;
    busy = true;
    _changed();
    SessionLogger? opened;
    try {
      participant = participantName.trim().isEmpty
          ? 'unassigned'
          : participantName.trim();
      if (participant != 'unassigned') {
        final profile = await ParticipantStore(
          directoryProvider: directoryProvider,
        ).resolve(participant, participantInfo, id: participantProfileId);
        participantId = profile.id;
        participant = profile.name;
        participantInfo = profile.info;
      } else {
        participantId = null;
        participantInfo = '';
      }
      await processing.load();
      opened = await SessionLogger.start(
        polarId: connected && polarId != null
            ? polarId!
            : ringDataFresh
            ? 'O2RING_${ringId!.replaceAll(RegExp(r'[^A-Za-z0-9]'), '')}'
            : 'MUSE_ATHENA',
        deviceName: connected
            ? deviceName
            : ringDataFresh
            ? ringName
            : 'Muse S Athena',
        primaryDeviceKind: connected
            ? 'polar_h10'
            : ringDataFresh
            ? 'wellue_o2ring'
            : 'muse_s_athena',
        additionalDevices: {
          ?polarId: {'name': deviceName, 'kind': 'polar_h10'},
          'MUSE_ATHENA': {
            'name': museAthena.deviceHint,
            'kind': 'muse_s_athena',
            'backend': 'brainflow_p21',
            'connected_at_start': museAthena.streaming,
          },
          ?ringId: {
            'name': ringName,
            'kind': 'wellue_o2ring',
            'ble_id': ringId,
            'decoder_version': 'viatom-legacy-live-13-v1',
          },
        },
        participantName: participant,
        participantId: participantId,
        description: description,
        directoryProvider: directoryProvider,
      );
      if (_disposed) {
        await opened.close();
        return;
      }
      await opened.writeEvent(
        'processing_configuration_initial',
        description: jsonEncode(
          processing.error == null
              ? processing.config.toJson()
              : {'settings_error': processing.error},
        ),
        flush: true,
      );
      if (museAthena.baseline != null) {
        await opened.writeEvent(
          'eeg_baseline_at_session_start',
          description: jsonEncode({
            'selected_utc': museAthena.baseline!.time.toIso8601String(),
            'channels': museAthena.baseline!.channels,
            'units': 'microvolt_squared',
          }),
        );
      }
      await opened.writeEvent(
        'eeg_processing_initial',
        description: jsonEncode({
          'version': 1,
          'method': 'hann_periodogram_1_30hz_v1',
          'bands_hz': {
            for (final e in eegBands.entries) e.key: [e.value.$1, e.value.$2],
          },
          'minimum_window_seconds': 2,
          'maximum_samples': 1024,
          'maximum_centered_microvolt': 250,
          'maximum_step_microvolt': 150,
          'minimum_variance': 0.01,
          'validated_relaxation_score': false,
        }),
      );
      await opened.writeEvent(
        'practice_state_at_session_start',
        description: jsonEncode(practice.settings),
      );
      await _foreground.start(opened.sessionId);
      if (_disposed) {
        await opened.close();
        await _stopForeground();
        return;
      }
      _eegRecordingSince = DateTime.now().toUtc();
      _ecgRecordingSince = _eegRecordingSince;
      _lastRecordedBand = museAthena.latestBands?.time;
      recordedEegSamples = 0;
      recordedAccSamples = 0;
      recordedEcgSamples = 0;
      _ecgSegment++;
      _ecgRecordingSince = DateTime.now().toUtc();
      await opened.writeEvent(
        'ecg_configuration_initial',
        description: ecgStatus,
      );
      _accSegment++;
      await opened.writeEvent(
        'accelerometer_configuration_initial',
        description: accelerationStatus,
      );
      sessionLogger = opened;
      _visibleSessionId = opened.sessionId;
      lastSessionLogger = null;
      recordedRingReadings = 0;
      rrHistory.clear();
      analysisInputs.clear();
      timeline.clear();
      eventTimes.clear();
      recordedMarkers.clear();
      markerNotes.clear();
      rmssd = null;
      _gap = false;
      _segment = 0;
      sessionStartedAt = DateTime.now();
      recordingState = RecordingState.recording;
      status = 'Recording';
      _exhausted = false;
      _waitingSince = _now;
      if (!connected && _target != null) _beginRecovery('disconnected');
    } catch (failure) {
      await opened?.close();
      await _stopForeground();
      error = 'Could not start session: $failure';
    } finally {
      busy = false;
      _changed();
    }
  }

  void _break(String reason) {
    _ecgSegment++;
    _accSegment++;
    if (_gap) return;
    _gap = true;
    _segment++;
    rrHistory.breakSequence();
    rmssd = null;
    _event('measurement_gap', description: reason);
  }

  void _onData(PolarHeartRateData data) {
    if (_disposed || _manualDisconnect || (!connected && !recovering)) return;
    final age = lastDataAge;
    if (_recording && age != null && age >= staleAfter && !_gap) {
      _event('measurement_stale');
      _break('stale stream');
    }
    _lastData = _now;
    heartRate = data.heartRate;
    if (data.rrIntervalsMs.isNotEmpty) latestRr = data.rrIntervalsMs.last;
    connected = true;
    connectionStatus = 'Receiving data';
    if (_firstData != null && !_firstData!.isCompleted) _firstData!.complete();
    if (_recording && sessionLogger != null) {
      if (_gap) {
        _event('measurement_recovered');
        _gap = false;
      }
      final samples = rrHistory.addAll(data.rrIntervalsMs);
      for (final (index, sample) in samples.indexed) {
        analysisInputs.add(
          RrInput(
            data.timestamp,
            sample.rrMs,
            _segment,
            packetIndex: index,
            recordedAccepted: sample.accepted,
          ),
        );
      }
      rmssd = rrHistory.rmssd;
      timeline.add(
        TimelinePoint(data.timestamp, data.heartRate, rmssd, _segment),
      );
      _save(
        sessionLogger!.logMeasurement(
          polarId: polarId ?? sessionLogger!.polarId,
          participantName: sessionLogger!.participantName,
          heartRate: data.heartRate,
          intervals: [
            for (final sample in samples)
              LoggedRr(
                rrMs: sample.rrMs,
                accepted: sample.accepted,
                artifactReason: sample.artifactReason,
              ),
          ],
          receivedAt: data.timestamp,
          continuitySegment: _segment,
        ),
      );
    }
    _changed();
  }

  void _lostConnection() {
    connected = false;
    connectionStatus = 'Disconnected';
    _event('bluetooth_disconnected');
    if (sessionLogger != null) _break('Bluetooth disconnected');
    if (_recording && !_manualDisconnect) _beginRecovery('disconnect');
    _changed();
  }

  void _tick() {
    if (_recording &&
        !_ringManualDisconnect &&
        !_ringConnectInFlight &&
        _ringTarget != null &&
        _now - _lastRingAttempt >= const Duration(seconds: 15) &&
        (!ringConnected ||
            ringDataAge == null ||
            (ringDataAge != null &&
                ringDataAge! >= const Duration(seconds: 15)))) {
      _event('o2ring_recovery_attempt', description: ringId);
      _save(connectRing(_ringTarget!));
    }
    final age = lastDataAge ?? (_now - _waitingSince);
    if (_recording &&
        _target != null &&
        !recovering &&
        !_exhausted &&
        !_manualDisconnect &&
        age >= staleAfter) {
      _event('measurement_stale');
      _beginRecovery('stale stream');
    }
    if (sessionLogger != null &&
        _now - _lastNotification >= const Duration(seconds: 5)) {
      _lastNotification = _now;
      _save(
        _foreground.update(
          state:
              '${recordingState == RecordingState.paused ? 'Paused' : 'Recording'} · $connectionStatus · data ${lastDataAge?.inSeconds.toString() ?? '--'}s ago${ringId == null ? '' : ' · O2 ${ringDataFresh ? latestRingReading?.spo2 ?? '--' : '--'}% · ring ${ringStatus.name}'}',
          heartRate: _gap ? null : heartRate,
          rmssd: _gap ? null : rmssd,
          artifactCount: rrHistory.artifactCount,
          elapsed: sessionElapsed,
        ),
      );
    }
    _changed();
  }

  void reconnect() {
    if (!canReconnect) return;
    _manualDisconnect = false;
    _exhausted = false;
    _beginRecovery('manual reconnect', manual: true);
  }

  void _beginRecovery(String reason, {bool manual = false}) {
    if (recovering ||
        _exhausted ||
        _target == null ||
        (!manual && !_recording)) {
      return;
    }
    _break(reason);
    recovering = true;
    connected = false;
    final epoch = ++_epoch;
    _save(_recover(epoch));
  }

  bool _current(int epoch) =>
      !_disposed && epoch == _epoch && !_manualDisconnect;

  Future<void> _recover(int epoch) async {
    try {
      for (
        var attempt = 1;
        attempt <= maxAttempts && _current(epoch);
        attempt++
      ) {
        connectionStatus = 'Reconnecting $attempt/$maxAttempts';
        _event(
          'recovery_attempt',
          description: 'attempt $attempt/$maxAttempts',
        );
        _changed();
        try {
          await polar.disconnect();
          if (!_current(epoch)) return;
          _firstData = Completer<void>();
          await polar.connect(_target!);
          if (!_current(epoch)) return;
          // A BLE link is not recovery: require an actual measurement.
          await _firstData!.future.timeout(staleAfter);
          if (!_current(epoch)) return;
          if (!connected) {
            throw StateError('Disconnected before recovery completed');
          }
          _event('recovery_succeeded');
          _exhausted = false;
          return;
        } catch (failure) {
          if (!_current(epoch)) return;
          _event('recovery_failed', description: 'attempt $attempt: $failure');
          await polar.disconnect();
          if (!_current(epoch)) return;
          if (attempt < maxAttempts) {
            _retryWait = Completer<void>();
            _retryTimer = Timer(
              retryDelay * attempt,
              () => _retryWait?.complete(),
            );
            await _retryWait!.future;
          }
        }
      }
      if (_current(epoch)) {
        connected = false;
        _exhausted = true;
        connectionStatus = 'Recovery exhausted — tap Reconnect H10';
        _event('recovery_exhausted');
      }
    } finally {
      if (_current(epoch)) {
        recovering = false;
        _firstData = null;
        _changed();
      }
    }
  }

  void _cancelRecovery() {
    _epoch++;
    _retryTimer?.cancel();
    if (_retryWait != null && !_retryWait!.isCompleted) _retryWait!.complete();
    if (_firstData != null && !_firstData!.isCompleted) _firstData!.complete();
    _firstData = null;
    if (recovering) {
      _save(polar.disconnect());
      connected = false;
      connectionStatus = 'Disconnected';
    }
    recovering = false;
  }

  void pause() {
    if (!_recording || busy) return;
    practice.pause();
    recordingState = RecordingState.paused;
    _cancelRecovery();
    _event('session_paused');
    _break('paused');
    _changed();
  }

  void resume() {
    if (recordingState != RecordingState.paused || busy) return;
    _eegRecordingSince = DateTime.now().toUtc();
    _ecgRecordingSince = _eegRecordingSince;
    recordingState = RecordingState.recording;
    _event('session_resumed');
    _exhausted = false;
    _waitingSince = _now;
    if (!connected && _target != null && !_manualDisconnect) {
      _beginRecovery('resume');
    }
    _changed();
  }

  Future<void> markEvent(String note) async {
    await _recordMarker(note: note);
  }

  Future<RecordedMarker?> markQuickMarker(QuickMarkerDefinition definition) =>
      _recordMarker(definition: definition);

  Future<RecordedMarker?> _recordMarker({
    QuickMarkerDefinition? definition,
    String note = '',
  }) async {
    final logger = sessionLogger;
    if (logger == null || busy) return null;
    final marker = RecordedMarker(
      id: newMarkerId(),
      sessionId: logger.sessionId,
      label: definition?.label ?? 'Event',
      timestamp: DateTime.now(),
    );
    await logger.writeEvent(
      'marked_event',
      description: definition?.label ?? note,
      receivedAt: marker.timestamp,
      eventId: marker.id,
      markerDefinitionId: definition?.id,
      markerLabel: marker.label,
      markerType: definition == null ? 'manual' : 'quick',
      flush: true,
    );
    // A slow write completing after a new session starts belongs to the old log.
    if (_disposed || _visibleSessionId != logger.sessionId) return marker;
    eventTimes.add(marker.timestamp);
    recordedMarkers.add(marker);
    _changed();
    return marker;
  }

  Future<void> addMarkerNote(RecordedMarker marker, String note) async {
    final logger = sessionLogger?.sessionId == marker.sessionId
        ? sessionLogger
        : lastSessionLogger;
    if (logger == null ||
        logger.sessionId != marker.sessionId ||
        !recordedMarkers.any((item) => item.id == marker.id)) {
      throw StateError(
        'This marker is no longer available in the current view',
      );
    }
    await logger.addMarkerNote(marker.id, note);
    if (recordedMarkers.any((item) => item.id == marker.id)) {
      markerNotes.putIfAbsent(marker.id, () => []).add(note.trim());
      _changed();
    }
  }

  Future<void> stop({String outcome = ''}) async {
    practice.stop();
    if (busy || sessionLogger == null) return;
    busy = true;
    recordingState = RecordingState.stopped;
    _cancelRecovery();
    final logger = sessionLogger!;
    sessionLogger = null;
    _changed();
    try {
      if (outcome.trim().isNotEmpty) {
        await logger.writeEvent('session_outcome', description: outcome);
      }
      await logger.close();
      lastSessionLogger = logger;
      status = 'Session saved';
    } catch (failure) {
      error = 'Could not save session: $failure';
    } finally {
      await _stopForeground();
      busy = false;
      _changed();
    }
  }

  Future<void> _stopForeground() async {
    try {
      await _foreground.stop();
    } catch (failure) {
      error = 'Could not stop foreground service: $failure';
    }
  }

  /// Explicit disconnection suppresses retries; the open session stays intact.
  Future<void> disconnect() async {
    if (busy) return;
    _manualDisconnect = true;
    _cancelRecovery();
    connecting = false;
    connected = false;
    connectionStatus = status = 'Manually disconnected';
    _event('bluetooth_manual_disconnect');
    if (sessionLogger != null) _break('manual disconnect');
    await polar.disconnect();
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    practice.dispose();
    quickMarkers.dispose();
    unawaited(_museBatchSubscription.cancel());
    museAthena.removeListener(_onMuseChanged);
    museAthena.dispose();
    _timer.cancel();
    _cancelRecovery();
    unawaited(_ringReadingSubscription.cancel());
    unawaited(_ringPacketSubscription.cancel());
    unawaited(_ringStatusSubscription.cancel());
    unawaited(ring.dispose());
    unawaited(_ecgSubscription.cancel());
    unawaited(_ecgStatusSubscription.cancel());
    unawaited(_accSubscription.cancel());
    unawaited(_pmdSubscription.cancel());
    unawaited(_accStatusSubscription.cancel());
    unawaited(_dataSubscription.cancel());
    unawaited(_connectionSubscription.cancel());
    unawaited(polar.dispose());
    final logger = sessionLogger;
    if (logger != null) {
      unawaited(logger.close());
      unawaited(_foreground.stop());
    }
    super.dispose();
  }
}
