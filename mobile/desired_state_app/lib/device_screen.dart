import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'session_controller.dart';
import 'o2_ring_service.dart';
import 'o2_ring_diagnostics_screen.dart';
import 'eeg_live_panel.dart';

/// Device discovery lives here; acquisition remains owned by SessionController.
class DeviceScreen extends StatefulWidget {
  const DeviceScreen({super.key, required this.controller});
  final SessionController controller;
  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  SessionController get _controller => widget.controller;
  final Map<String, List<ScanResult>> _results = {};
  String _scanKind = 'h10';
  bool _scanning = false;
  String? _scanStatus;
  final TextEditingController _athenaSerial = TextEditingController();

  @override
  void dispose() {
    _athenaSerial.dispose();
    super.dispose();
  }

  Future<void> _connectAthena() async {
    final permissions = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    if (!(permissions[Permission.bluetoothScan]?.isGranted ?? false) ||
        !(permissions[Permission.bluetoothConnect]?.isGranted ?? false)) {
      _controller.museAthena.reportStatus('Nearby devices permission denied');
      return;
    }
    await _controller.museAthena.connect(serialNumber: _athenaSerial.text);
  }

  Widget _athenaCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: ListenableBuilder(
        listenable: _controller.museAthena,
        builder: (context, _) {
          final muse = _controller.museAthena;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Muse S Athena',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Text(
                'EEG and motion · included when recording. Detailed diagnostics below.',
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _athenaSerial,
                enabled: !muse.streaming && !muse.busy,
                decoration: const InputDecoration(
                  labelText: 'Advertised Muse name (optional)',
                  hintText: 'MuseS-XXXX',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed:
                        muse.busy ||
                            muse.streaming ||
                            _scanning ||
                            _controller.connecting ||
                            _controller.busy
                        ? null
                        : _connectAthena,
                    icon: Icon(
                      muse.streaming
                          ? Icons.sensors
                          : Icons.bluetooth_searching,
                    ),
                    label: Text(muse.busy ? 'Starting…' : 'Connect & stream'),
                  ),
                  if (muse.streaming)
                    OutlinedButton.icon(
                      onPressed: muse.busy ? null : muse.disconnect,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('Disconnect'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(muse.status),
              if (muse.streaming || muse.eegSamples > 0)
                ExpansionTile(
                  title: const Text('Athena diagnostics'),
                  children: [
                    Text(
                      '${muse.deviceHint} · EEG ${muse.eegRate} Hz (${muse.eegSamples} samples) · motion ${muse.motionRate} Hz (${muse.motionSamples} samples)',
                    ),
                    if (muse.latestEeg.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'EEG latest values (µV by BrainFlow channel order)',
                      ),
                      for (final entry in muse.latestEeg.entries)
                        Text('${entry.key}: ${entry.value.toStringAsFixed(2)}'),
                    ],
                    if (muse.eegHistory.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text('Raw EEG · shared zero and µV scale'),
                      SizedBox(
                        height: 150,
                        width: double.infinity,
                        child: CustomPaint(
                          painter: _MuseEegPainter(
                            muse.eegHistory,
                            muse.eegRate,
                          ),
                        ),
                      ),
                    ],
                    if (muse.latestAccel.isNotEmpty)
                      Text(
                        'Motion latest · ${muse.latestAccel.entries.map((e) => '${e.key} ${e.value.toStringAsFixed(3)}').join(' · ')}',
                      ),
                    if (muse.latestGyro.isNotEmpty)
                      Text(
                        'Gyroscope latest · ${muse.latestGyro.entries.map((e) => '${e.key} ${e.value.toStringAsFixed(3)}').join(' · ')}',
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    ),
  );
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

  Future<void> _scan(String kind) async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _scanKind = kind;
      _results[kind] = [];
      _scanStatus = kind == 'h10'
          ? 'Scanning for Polar H10...'
          : 'Scanning for O2Ring...';
    });

    try {
      final permissionOk = await _requestPermissions();
      if (!mounted) return;
      if (!permissionOk) {
        setState(() => _scanStatus = 'Bluetooth permission denied');
        return;
      }
      final results = await _scanOne(kind);

      if (!mounted) return;

      setState(() {
        _results[kind] = results;
        _scanStatus = results.isEmpty
            ? 'No supported device found'
            : 'Found ${results.length} device(s)';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _scanStatus = 'Scan error: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _scanning = false;
        });
      }
    }
  }

  Future<List<ScanResult>> _scanOne(String kind) async {
    if (kind == 'h10') return _controller.polar.scan();
    final adapter = O2RingService();
    try {
      return await adapter.scan();
    } finally {
      await adapter.dispose();
    }
  }

  Widget _scanControls(String kind) => Column(
    children: [
      FilledButton.icon(
        onPressed:
            _scanning ||
                _controller.connecting ||
                _controller.busy ||
                _controller.museAthena.busy
            ? null
            : () => _scan(kind),
        icon: const Icon(Icons.bluetooth_searching),
        label: Text(
          _scanning && _scanKind == kind
              ? 'Searching...'
              : kind == 'h10'
              ? 'Scan for Polar H10'
              : 'Scan for O2Ring',
        ),
      ),
      if (_scanKind == kind && _scanStatus != null) Text(_scanStatus!),
      for (final result in _results[kind] ?? <ScanResult>[])
        ListTile(
          title: Text(
            result.device.platformName.isEmpty
                ? (kind == 'h10' ? 'Polar H10' : 'O2Ring')
                : result.device.platformName,
          ),
          subtitle: Text(result.device.remoteId.str),
          trailing: const Icon(Icons.bluetooth_connected),
          onTap: _controller.connecting || _controller.busy
              ? null
              : () async {
                  try {
                    await _connect(result, kind);
                  } catch (error) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Connection failed: $error')),
                      );
                    }
                  }
                },
        ),
    ],
  );

  Future<void> _connect(ScanResult result, String kind) async {
    _scanStatus = null;
    if (kind == 'ring') {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              O2RingDiagnosticsScreen(controller: _controller, result: result),
        ),
      );
      return;
    }
    await _controller.connect(result.device);
  }

  Future<void> _disconnect() => _controller.disconnect();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Polar H10',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(_controller.deviceName),
                    Text(_controller.error ?? _controller.connectionStatus),
                    if (_controller.polarId != null) ...[
                      Text('H10 ACC: ${_controller.accelerationStatus}'),
                      Text('H10 ECG: ${_controller.ecgStatus}'),
                    ],
                    if (_controller.canReconnect)
                      FilledButton.icon(
                        onPressed: _controller.reconnect,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Reconnect H10'),
                      ),
                    if (_controller.connected || _controller.polarId != null)
                      TextButton(
                        onPressed: _controller.busy ? null : _disconnect,
                        child: const Text('Disconnect H10'),
                      ),
                    if (_controller.sessionLogger == null) _scanControls('h10'),
                    if (_controller.sessionLogger != null)
                      const Text(
                        'Reconnect keeps this session. Stop before selecting a different H10.',
                      ),
                  ],
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'O2Ring',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      '${_controller.ringName} · ${_controller.ringStatus.name}',
                    ),
                    Text(
                      'O2Ring rows recorded: ${_controller.recordedRingReadings}',
                    ),
                    if (_controller.ringDevice != null)
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => O2RingDiagnosticsScreen(
                                  controller: _controller,
                                ),
                              ),
                            ),
                            icon: const Icon(Icons.sensors),
                            label: const Text('O2Ring diagnostics'),
                          ),
                          TextButton(
                            onPressed: _controller.disconnectRing,
                            child: const Text('Disconnect O2Ring'),
                          ),
                        ],
                      ),
                    if (_controller.sessionLogger == null)
                      _scanControls('ring'),
                  ],
                ),
              ),
            ),
            if (Theme.of(context).platform == TargetPlatform.android)
              _athenaCard(),
          ],
        ),
      ),
    ),
  );
}

class _MuseEegPainter extends CustomPainter {
  _MuseEegPainter(this.channels, this.rate);
  final int rate;
  final Map<String, List<double>> channels;
  @override
  void paint(Canvas canvas, Size size) {
    final series = <String, List<(double, double)>>{};
    var limit = 1.0;
    for (final entry in channels.entries) {
      series[entry.key] = [
        for (var i = 0; i < entry.value.length; i++)
          (
            (i - entry.value.length + 1) / (rate > 0 ? rate : 256),
            entry.value[i],
          ),
      ];
      for (final value in entry.value) {
        if (value.abs() > limit) limit = value.abs();
      }
    }
    EegAxisPainter(
      series,
      left: -1024 / (rate > 0 ? rate : 256),
      right: 0,
      minimum: -limit,
      maximum: limit,
      yLabel: 'Raw EEG (µV)',
      colors: {
        for (final (index, key) in series.keys.indexed)
          key: [
            Colors.blue,
            Colors.deepOrange,
            Colors.teal,
            Colors.purple,
          ][index % 4],
      },
    ).paint(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _MuseEegPainter oldDelegate) => true;
}
