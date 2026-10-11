import 'package:flutter/material.dart';

import 'session_controller.dart';
import 'processing_screen.dart';
import 'processing.dart';
import 'processing_presets.dart';
import 'session_preferences.dart';
import 'plot_inspection.dart';

class PreferencesScreen extends StatefulWidget {
  const PreferencesScreen({super.key, required this.controller, this.streams});
  final SessionController controller;
  final List<String>? streams;
  @override
  State<PreferencesScreen> createState() => _PreferencesScreenState();
}

class _PreferencesScreenState extends State<PreferencesScreen> {
  bool _ready = false, _saving = false;
  String? _error;
  Set<String> _recording = {};
  Set<String> _hiddenInspection = {'ECG'};
  bool _eeg = true, _oxygen = true, _posture = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await widget.controller.loadUserSettings();
      await widget.controller.processing.load();
      if (widget.controller.processing.error != null) {
        throw StateError(widget.controller.processing.error!);
      }
      final prefs = widget.controller.preferences;
      if (!mounted) {
        return;
      }
      setState(() {
        _recording = {...prefs.recording};
        _hiddenInspection = {...prefs.hiddenInspection};
        _eeg = prefs.showEeg;
        _oxygen = prefs.showOxygen;
        _posture = prefs.showPosture;
        _ready = true;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = '$error');
      }
    }
  }

  Future<void> _save([ProcessingConfig? config]) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (config != null) await widget.controller.saveProcessing(config);
      await widget.controller.savePreferences(
        widget.controller.preferences.copyWith(
          recording: _recording,
          hiddenInspection: _hiddenInspection,
          showEeg: _eeg,
          showOxygen: _oxygen,
          showPosture: _posture,
        ),
      );
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_ready && widget.streams == null) {
      return ProcessingEditor(
        config: widget.controller.processing.config,
        presets: ProcessingPresets(
          directoryProvider: widget.controller.directoryProvider,
        ),
        title: 'Recording settings',
        extraChildren: _displayChoices(),
        onApply: (config) async {
          await _save(config);
          if (_error != null) throw StateError(_error!);
        },
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.streams == null
              ? 'Recording display settings'
              : 'Recording settings',
        ),
        actions: [
          TextButton(
            onPressed: _ready && !_saving ? _save : null,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        children: [
          if (_error != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
          if (!_ready && _error == null) const LinearProgressIndicator(),
          if (_ready && widget.streams != null) ...[
            const ListTile(
              title: Text('Save these acquired streams'),
              subtitle: Text(
                'Signals stay available in Metric details and diagnostics. ECG is off for new settings; saved choices are retained. Posture estimates can be saved without raw acceleration. Changes during recording are timestamped.',
              ),
            ),
            for (final key in widget.streams!)
              SwitchListTile(
                title: Text(recordingStreams[key]!),
                value: _recording.contains(key),
                onChanged: _saving
                    ? null
                    : (v) => setState(
                        () => v ? _recording.add(key) : _recording.remove(key),
                      ),
              ),
          ],
        ],
      ),
    );
  }

  List<Widget> _displayChoices() => [
    ExpansionTile(
      title: const Text('Touch readout'),
      subtitle: const Text('Choose values shown when touching a plot'),
      children: [
        for (final name in {
          ...inspectionOrder,
          ...widget.controller.inspectionFields,
          ...widget.controller.museAthena.opticalHistory.keys.map(
            (k) => 'Optical $k',
          ),
          ...widget.controller.museAthena.eegHistory.keys.map((k) => 'EEG $k'),
          'ACC X',
          'ACC Y',
          'ACC Z',
          ...widget.controller.processing.config.metrics.map(inspectionKey),
          ..._hiddenInspection,
        })
          SwitchListTile(
            title: Text(name == 'HRV' ? 'HRV (RMSSD)' : name),
            value: !_hiddenInspection.contains(name),
            onChanged: _saving
                ? null
                : (v) => setState(
                    () => v
                        ? _hiddenInspection.remove(name)
                        : _hiddenInspection.add(name),
                  ),
          ),
      ],
    ),
    ExpansionTile(
      title: const Text('Saved sensor streams'),
      subtitle: const Text('Recording choices are independent of display'),
      children: [
        for (final entry in recordingStreams.entries)
          SwitchListTile(
            title: Text(entry.value),
            value: _recording.contains(entry.key),
            onChanged: _saving
                ? null
                : (v) => setState(
                    () => v
                        ? _recording.add(entry.key)
                        : _recording.remove(entry.key),
                  ),
          ),
      ],
    ),
    const ListTile(
      title: Text('Visible during Recording'),
      subtitle: Text('Display choices do not change recording.'),
    ),
    SwitchListTile(
      title: const Text('Compact EEG trends'),
      value: _eeg,
      onChanged: _saving ? null : (v) => setState(() => _eeg = v),
    ),
    SwitchListTile(
      title: const Text('Oxygen and pulse'),
      value: _oxygen,
      onChanged: _saving ? null : (v) => setState(() => _oxygen = v),
    ),
    SwitchListTile(
      title: const Text('Posture'),
      value: _posture,
      onChanged: _saving ? null : (v) => setState(() => _posture = v),
    ),
  ];
}
