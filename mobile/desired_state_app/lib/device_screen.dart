import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'session_controller.dart';

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
      _scanStatus = 'Scanning for Polar H10...';
    });

    try {
      final permissionOk = await _requestPermissions();
      if (!mounted) return;
      if (!permissionOk) {
        setState(() => _scanStatus = 'Bluetooth permission denied');
        return;
      }
      final results = await _controller.polar.scan();

      if (!mounted) return;

      setState(() {
        _scanResults = results;
        _scanStatus = results.isEmpty
            ? 'No Polar H10 found'
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

  Future<void> _connect(ScanResult result) async {
    _scanStatus = null;
    await _controller.connect(result.device);
  }

  Future<void> _disconnect() => _controller.disconnect();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Connect H10')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(_controller.deviceName),
            Text(_controller.error ?? _controller.connectionStatus),
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
                label: Text(_scanning ? 'Searching...' : 'Scan for Polar H10'),
              ),
              for (final result in _scanResults)
                ListTile(
                  title: Text(
                    result.device.platformName.isEmpty
                        ? 'Polar / BLE device'
                        : result.device.platformName,
                  ),
                  subtitle: Text(result.device.remoteId.str),
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
