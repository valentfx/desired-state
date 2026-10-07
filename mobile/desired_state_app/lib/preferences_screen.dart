import 'package:flutter/material.dart';

import 'session_controller.dart';
import 'processing_screen.dart';
import 'session_preferences.dart';

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
  bool _eeg = true, _oxygen = true, _posture = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await widget.controller.loadUserSettings();
      final prefs = widget.controller.preferences;
      if (!mounted) {
        return;
      }
      setState(() {
        _recording = {...prefs.recording};
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

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.controller.savePreferences(
        SessionPreferences(
          recording: _recording,
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.streams == null
            ? 'Session display settings'
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
        if (_ready && widget.streams == null) ...[
          const ListTile(
            title: Text('Visible during Session'),
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
          ListTile(
            title: const Text('Processing & plots'),
            subtitle: const Text('BPM, HRV metrics and filters'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => ProcessingScreen(controller: widget.controller),
              ),
            ),
          ),
        ],
        if (_ready && widget.streams != null) ...[
          const ListTile(
            title: Text('Save these acquired streams'),
            subtitle: Text(
              'Signals stay available in diagnostics. Changes during recording are timestamped.',
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
