import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'polar_h10_service.dart';
import 'recording_foreground_service.dart';
import 'rr_history.dart';
import 'session_logger.dart';
import 'quick_markers.dart';
import 'processing.dart';

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
    RecordingForegroundService? foregroundService,
    this.directoryProvider,
    this.staleAfter = const Duration(seconds: 10),
    this.retryDelay = const Duration(seconds: 2),
    this.maxAttempts = 3,
    this.elapsedClock,
    Duration tickInterval = const Duration(seconds: 1),
  }) : polar = service ?? PolarH10Service(),
       quickMarkers = QuickMarkerStore(directoryProvider: directoryProvider),
       processing = ProcessingStore(directoryProvider: directoryProvider),
       _foreground = foregroundService ?? RecordingForegroundService() {
    assert(maxAttempts > 0 && staleAfter > Duration.zero);
    _dataSubscription = polar.dataStream.listen(_onData);
    _connectionSubscription = polar.connectionStream.listen((connected) {
      if (!connected) _lostConnection();
    });
    _timer = Timer.periodic(tickInterval, (_) => _tick());
  }

  final PolarH10Service polar;
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
    String description = '',
  }) async {
    if (!connected || sessionLogger != null || busy || polarId == null) return;
    busy = true;
    _changed();
    SessionLogger? opened;
    try {
      participant = participantName.trim().isEmpty
          ? 'unassigned'
          : participantName.trim();
      await processing.load();
      opened = await SessionLogger.start(
        polarId: polarId!,
        deviceName: deviceName,
        participantName: participant,
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
      await _foreground.start(opened.sessionId);
      if (_disposed) {
        await opened.close();
        await _stopForeground();
        return;
      }
      sessionLogger = opened;
      _visibleSessionId = opened.sessionId;
      lastSessionLogger = null;
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
      if (!connected) _beginRecovery('disconnected');
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
          polarId: sessionLogger!.polarId,
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
    final age = lastDataAge ?? (_now - _waitingSince);
    if (_recording &&
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
              '${recordingState == RecordingState.paused ? 'Paused' : 'Recording'} · $connectionStatus · data ${lastDataAge?.inSeconds.toString() ?? '--'}s ago',
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
    recordingState = RecordingState.paused;
    _cancelRecovery();
    _event('session_paused');
    _break('paused');
    _changed();
  }

  void resume() {
    if (recordingState != RecordingState.paused || busy) return;
    recordingState = RecordingState.recording;
    _event('session_resumed');
    _exhausted = false;
    _waitingSince = _now;
    if (!connected && !_manualDisconnect) _beginRecovery('resume');
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
    quickMarkers.dispose();
    _timer.cancel();
    _cancelRecovery();
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
