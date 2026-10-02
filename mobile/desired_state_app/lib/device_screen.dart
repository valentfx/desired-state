import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'session_controller.dart';
import 'o2_ring_service.dart';
import 'o2_ring_diagnostics_screen.dart';

/// Device discovery lives here; acquisition remains owned by SessionController.
class DeviceScreen extends StatefulWidget {
  const DeviceScreen({super.key, required this.controller});
  final SessionController controller;
  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  SessionController get _controller => widget.controller;
  List<ScanResult> _scanResults = [];
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
                'BrainFlow Android stream · EEG and motion diagnostics. This test stream is not yet saved in session recordings.',
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
                            _controller.busy ||
                            _controller.sessionLogger != null
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
              if (muse.streaming || muse.eegSamples > 0) ...[
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
                  const Text('EEG · relative channel traces'),
                  SizedBox(
                    height: 150,
                    width: double.infinity,
                    child: CustomPaint(
                      painter: _MuseEegPainter(muse.eegHistory),
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

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _scanResults = [];
      _scanStatus = 'Scanning for Polar H10 and O2Ring...';
    });

    try {
      final permissionOk = await _requestPermissions();
      if (!mounted) return;
      if (!permissionOk) {
        setState(() => _scanStatus = 'Bluetooth permission denied');
        return;
      }
      final results = await _scanAll();

      if (!mounted) return;

      setState(() {
        _scanResults = results;
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

  Future<List<ScanResult>> _scanAll() async {
    // The adapter scans are serialized because FlutterBlue owns one scanner.
    // A broad O2Ring scan is run first; the existing H10 service then performs
    // its service-filtered discovery without changing H10 connection behavior.
    final adapter = O2RingService();
    final ring = await adapter.scan();
    await adapter.dispose();
    final h10 = await _controller.polar.scan();
    final seen = <String>{};
    return [
      ...ring,
      ...h10,
    ].where((result) => seen.add(result.device.remoteId.str)).toList();
  }

  Future<void> _connect(ScanResult result) async {
    _scanStatus = null;
    if (O2RingService.isCandidate(result)) {
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
            if (Theme.of(context).platform == TargetPlatform.android)
              _athenaCard(),
            if (_controller.ringDevice != null) ...[
              Text('${_controller.ringName} · ${_controller.ringStatus.name}'),
              Text('O2Ring rows recorded: ${_controller.recordedRingReadings}'),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        O2RingDiagnosticsScreen(controller: _controller),
                  ),
                ),
                icon: const Icon(Icons.sensors),
                label: const Text('O2Ring diagnostics'),
              ),
            ],
            Text(_controller.deviceName),
            Text(_controller.error ?? _controller.connectionStatus),
            if (_controller.polarId != null)
              Text('H10 ACC: ${_controller.accelerationStatus}'),
            if (_scanStatus != null) Text(_scanStatus!),
            if (_controller.sessionLogger != null)
              const Text(
                'This recording keeps its assigned strap. Reconnect preserves the session; stop before selecting another device.',
              ),
            if (_controller.canReconnect)
              FilledButton.icon(
                onPressed: _controller.reconnect,
                icon: const Icon(Icons.refresh),
                label: const Text('Reconnect H10'),
              ),
            if (_controller.connected || _controller.sessionLogger != null)
              TextButton(
                onPressed: _controller.busy ? null : _disconnect,
                child: const Text('Disconnect'),
              ),
            if (_controller.sessionLogger == null) ...[
              FilledButton.icon(
                onPressed:
                    _scanning ||
                        _controller.connecting ||
                        _controller.busy ||
                        _controller.museAthena.streaming ||
                        _controller.museAthena.busy
                    ? null
                    : _scan,
                icon: const Icon(Icons.bluetooth_searching),
                label: Text(_scanning ? 'Searching...' : 'Scan for devices'),
              ),
              for (final result in _scanResults)
                ListTile(
                  title: Text(
                    result.device.platformName.isEmpty
                        ? (O2RingService.isCandidate(result)
                              ? 'Viatom / Wellue O2Ring candidate'
                              : 'Polar H10')
                        : result.device.platformName,
                  ),
                  subtitle: Text(
                    O2RingService.isCandidate(result)
                        ? '${result.device.remoteId.str} · Open diagnostics'
                        : result.device.remoteId.str,
                  ),
                  onTap: _controller.connecting || _controller.busy
                      ? null
                      : () => _connect(result),
                ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _MuseEegPainter extends CustomPainter {
  _MuseEegPainter(this.channels);
  final Map<String, List<double>> channels;
  static const _colors = <Color>[
    Colors.blue,
    Colors.deepOrange,
    Colors.green,
    Colors.purple,
    Colors.teal,
    Colors.red,
    Colors.indigo,
    Colors.brown,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final grid = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    var series = 0;
    for (final points in channels.values) {
      if (points.length < 2) {
        series++;
        continue;
      }
      final visible = points.length > 512
          ? points.sublist(points.length - 512)
          : points;
      var low = visible.first;
      var high = visible.first;
      for (final value in visible) {
        if (value < low) low = value;
        if (value > high) high = value;
      }
      final span = high - low;
      final path = Path();
      for (var i = 0; i < visible.length; i++) {
        final x = size.width * i / (visible.length - 1);
        final normalized = span == 0 ? 0.5 : (visible[i] - low) / span;
        final y = size.height * (0.1 + 0.8 * (1 - normalized));
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = _colors[series % _colors.length]
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
      series++;
    }
  }

  @override
  bool shouldRepaint(covariant _MuseEegPainter oldDelegate) => true;
}
