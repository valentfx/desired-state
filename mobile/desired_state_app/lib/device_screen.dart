import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'session_controller.dart';
import 'o2_ring_service.dart';
import 'o2_ring_diagnostics_screen.dart';

/// Device discovery is navigation only; recording remains app-owned.
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
                    _scanning || _controller.connecting || _controller.busy
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
