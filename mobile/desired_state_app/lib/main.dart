import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import 'polar_h10_service.dart';
import 'rr_history.dart';
import 'recording_foreground_service.dart';
import 'session_logger.dart';

void main() {
  runApp(const DesiredStateApp());
}

class DesiredStateApp extends StatelessWidget {
  const DesiredStateApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Desired State',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const CollectorScreen(),
    );
  }
}

class CollectorScreen extends StatefulWidget {
  const CollectorScreen({super.key, this.service});

  final PolarH10Service? service;

  @override
  State<CollectorScreen> createState() => _CollectorScreenState();
}

class _CollectorScreenState extends State<CollectorScreen> {
  late final PolarH10Service _polar;

  StreamSubscription<PolarHeartRateData>? _dataSubscription;

  List<ScanResult> _scanResults = [];

  bool _scanning = false;
  bool _connecting = false;
  bool _connected = false;

  String _status = 'Ready';
  String _deviceName = 'No H10 connected';

  int? _heartRate;
  double? _latestRr;
  double? _rmssd;
  String? _polarId;
  String? _sessionId;
  RecordingState _recordingState = RecordingState.stopped;
  bool _exporting = false;

  final RrHistory _rrHistory = RrHistory();
  final TextEditingController _participantNameController =
      TextEditingController();
  final TextEditingController _eventDescriptionController =
      TextEditingController();
  SessionLogger? _sessionLogger;
  SessionLogger? _lastSessionLogger;
  final RecordingForegroundService _foregroundService =
      RecordingForegroundService();

  @override
  void initState() {
    super.initState();
    _polar = widget.service ?? PolarH10Service();

    _dataSubscription = _polar.dataStream.listen((data) {
      final logger = _sessionLogger;
      final polarId = _polarId;
      if (_recordingState == RecordingState.recording &&
          logger != null &&
          polarId != null) {
        final intervals = _rrHistory.addAll(data.rrIntervalsMs);
        unawaited(
          logger.logMeasurement(
            polarId: polarId,
            participantName: _participantName(),
            heartRate: data.heartRate,
            intervals: [
              for (final interval in intervals)
                LoggedRr(
                  rrMs: interval.rrMs,
                  accepted: interval.accepted,
                  artifactReason: interval.artifactReason,
                ),
            ],
            receivedAt: data.timestamp,
          ),
        );
      }

      setState(() {
        _heartRate = data.heartRate;

        if (data.rrIntervalsMs.isNotEmpty) {
          _latestRr = data.rrIntervalsMs.last;
        }

        if (_recordingState == RecordingState.recording) {
          _rmssd = _rrHistory.rmssd;
        }
      });
    });
  }

  Future<bool> _requestPermissions() async {
    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.notification,
    ].request();

    final scanOk = results[Permission.bluetoothScan]?.isGranted ?? false;
    final connectOk = results[Permission.bluetoothConnect]?.isGranted ?? false;

    return scanOk && connectOk;
  }

  Future<void> _scan() async {
    final permissionOk = await _requestPermissions();

    if (!permissionOk) {
      setState(() {
        _status = 'Bluetooth permission denied';
      });
      return;
    }

    setState(() {
      _scanning = true;
      _scanResults = [];
      _status = 'Scanning for Polar H10...';
    });

    try {
      final results = await _polar.scan();

      if (!mounted) return;

      setState(() {
        _scanResults = results;
        _status = results.isEmpty
            ? 'No Polar H10 found'
            : 'Found ${results.length} device(s)';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _status = 'Scan error: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _scanning = false;
        });
      }
    }
  }

  Future<void> _connect(ScanResult result) async {
    setState(() {
      _connecting = true;
      _status = 'Connecting...';
    });

    try {
      await _polar.connect(result.device);

      final name = result.device.platformName.trim();
      final deviceName = name.isEmpty ? result.device.remoteId.str : name;
      final polarId = _polarIdFrom(deviceName, result.device.remoteId.str);
      if (!mounted) {
        return;
      }

      setState(() {
        _connected = true;
        _deviceName = deviceName;
        _polarId = polarId;
        _status = 'Connected — ready to record';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _connected = false;
        _status = 'Connection error: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _connecting = false;
        });
      }
    }
  }

  Future<void> _disconnect() async {
    await _polar.disconnect();
    await _stopSession();

    if (!mounted) return;

    setState(() {
      _connected = false;
      _heartRate = null;
      _latestRr = null;
      _rmssd = null;
      _rrHistory.clear();
      _polarId = null;
      _deviceName = 'No H10 connected';
      _status = 'Disconnected';
    });
  }

  @override
  void dispose() {
    _dataSubscription?.cancel();
    _polar.dispose();
    _participantNameController.dispose();
    _eventDescriptionController.dispose();
    super.dispose();
  }

  String _participantName() {
    final name = _participantNameController.text.trim();
    return name.isEmpty ? 'unassigned' : name;
  }

  String _polarIdFrom(String deviceName, String fallback) {
    final match = RegExp(r'([A-Za-z0-9]{8})$').firstMatch(deviceName.trim());
    return (match?.group(1) ?? fallback).toUpperCase();
  }

  Future<void> _markEvent() async {
    final logger = _sessionLogger;
    if (logger == null) return;
    await logger.writeEvent(
      'marked_event',
      description: _eventDescriptionController.text,
    );
    if (!mounted) return;
    setState(_eventDescriptionController.clear);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Event saved to this session log.')),
    );
  }

  Future<void> _startSession() async {
    final polarId = _polarId;
    if (polarId == null || !_connected) return;
    try {
      final logger = await SessionLogger.start(
        polarId: polarId,
        deviceName: _deviceName,
        participantName: _participantName(),
      );
      await _foregroundService.start(logger.sessionId);
      if (!mounted) {
        await _foregroundService.stop();
        await logger.close();
        return;
      }
      setState(() {
        _rrHistory.clear();
        _rmssd = null;
        _sessionLogger = logger;
        _sessionId = logger.sessionId;
        _recordingState = RecordingState.recording;
        _status = 'Recording';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Could not start session log: $error');
    }
  }

  Future<void> _pauseSession() async {
    final logger = _sessionLogger;
    if (logger == null || _recordingState != RecordingState.recording) return;
    await logger.writeEvent('session_paused');
    await _foregroundService.stop();
    if (!mounted) return;
    setState(() {
      _recordingState = RecordingState.paused;
      _status = 'Recording paused';
    });
  }

  Future<void> _resumeSession() async {
    final logger = _sessionLogger;
    if (logger == null || _recordingState != RecordingState.paused) return;
    await _foregroundService.start(logger.sessionId);
    await logger.writeEvent('session_resumed');
    if (!mounted) return;
    setState(() {
      _recordingState = RecordingState.recording;
      _status = 'Recording';
    });
  }

  Future<void> _stopSession() async {
    final logger = _sessionLogger;
    if (logger == null) return;
    await logger.close();
    await _foregroundService.stop();
    if (!mounted) return;
    setState(() {
      _sessionLogger = null;
      _lastSessionLogger = logger;
      _recordingState = RecordingState.stopped;
      _status = _connected ? 'Session saved' : _status;
    });
  }

  Future<void> _exportLastSession() async {
    final logger = _lastSessionLogger;
    if (logger == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      final zip = await logger.createExportZip();
      await SharePlus.instance.share(
        ShareParams(
          subject: 'Desired State session ${logger.sessionId}',
          text: 'Desired State H10 session ${logger.sessionId}',
          files: [XFile(zip.path)],
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not export session: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Desired State')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Polar H10 Collector',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(_status),
            if (_sessionId != null) ...[
              const SizedBox(height: 4),
              Text('Session: $_sessionId'),
            ],
            const SizedBox(height: 24),

            TextField(
              controller: _participantNameController,
              enabled: _sessionLogger == null,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Participant name',
                helperText: 'Saved with the H10 ID for this session.',
              ),
            ),

            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text(
                      _deviceName,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 20),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _Metric(
                          label: 'Heart Rate',
                          value: _heartRate?.toString() ?? '--',
                          unit: 'bpm',
                        ),
                        _Metric(
                          label: 'RR',
                          value: _latestRr == null
                              ? '--'
                              : _latestRr!.toStringAsFixed(0),
                          unit: 'ms',
                        ),
                        _Metric(
                          label: 'RMSSD (clean)',
                          value: _rmssd == null
                              ? '--'
                              : _rmssd!.toStringAsFixed(1),
                          unit: 'ms',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            if (!_connected)
              FilledButton.icon(
                onPressed: _scanning ? null : _scan,
                icon: _scanning
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bluetooth_searching),
                label: Text(_scanning ? 'Scanning...' : 'Scan for Polar H10'),
              ),

            if (_connected)
              OutlinedButton.icon(
                onPressed: _disconnect,
                icon: const Icon(Icons.bluetooth_disabled),
                label: const Text('Disconnect'),
              ),

            if (_connected) ...[
              const SizedBox(height: 12),
              if (_recordingState == RecordingState.stopped)
                FilledButton.icon(
                  onPressed: _startSession,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('START RECORDING'),
                ),
              if (_recordingState == RecordingState.recording)
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: _pauseSession,
                        icon: const Icon(Icons.pause),
                        label: const Text('PAUSE'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: _stopSession,
                        icon: const Icon(Icons.stop),
                        label: const Text('STOP & SAVE'),
                      ),
                    ),
                  ],
                ),
              if (_recordingState == RecordingState.paused)
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _resumeSession,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('CONTINUE'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: _stopSession,
                        icon: const Icon(Icons.stop),
                        label: const Text('STOP & SAVE'),
                      ),
                    ),
                  ],
                ),
            ],

            if (_lastSessionLogger != null && _sessionLogger == null) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: _exporting ? null : _exportLastSession,
                icon: _exporting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.ios_share),
                label: Text(
                  _exporting
                      ? 'PREPARING EXPORT...'
                      : 'SHARE COMPLETED SESSION',
                ),
              ),
            ],

            const SizedBox(height: 24),

            if (_scanResults.isNotEmpty && !_connected) ...[
              Text('Devices', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),

              for (final result in _scanResults)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.monitor_heart),
                    title: Text(
                      result.device.platformName.isEmpty
                          ? 'Polar / BLE device'
                          : result.device.platformName,
                    ),
                    subtitle: Text(
                      '${result.device.remoteId.str}   RSSI ${result.rssi}',
                    ),
                    trailing: _connecting
                        ? const CircularProgressIndicator()
                        : const Icon(Icons.chevron_right),
                    onTap: _connecting ? null : () => _connect(result),
                  ),
                ),
            ],

            const SizedBox(height: 32),

            TextField(
              controller: _eventDescriptionController,
              enabled: _connected,
              maxLines: 2,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Event description',
                hintText: 'Example: began slow breathing',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _recordingState == RecordingState.recording
                  ? _markEvent
                  : null,
              icon: const Icon(Icons.flag),
              label: const Text('MARK EVENT'),
            ),

            const SizedBox(height: 12),

            Text(
              'Raw RR this session: ${_rrHistory.rawCount}\n'
              'Accepted RR: ${_rrHistory.cleanCount}\n'
              'Artifacts rejected: ${_rrHistory.artifactCount}',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

enum RecordingState { stopped, recording, paused }

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.unit});

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label),
        const SizedBox(height: 8),
        Text(value, style: Theme.of(context).textTheme.headlineMedium),
        Text(unit),
      ],
    );
  }
}
