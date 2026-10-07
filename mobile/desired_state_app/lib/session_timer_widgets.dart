import 'package:flutter/material.dart';

import 'session_controller.dart';
import 'session_timer.dart';

class SessionTimerSetup extends StatefulWidget {
  const SessionTimerSetup({super.key, required this.controller});
  final SessionController controller;
  @override
  State<SessionTimerSetup> createState() => _SessionTimerSetupState();
}

class _SessionTimerSetupState extends State<SessionTimerSetup> {
  late final store = SessionTimerPreferenceStore(
    directoryProvider: widget.controller.directoryProvider,
  );
  SessionTimerPreference preference = const SessionTimerPreference();
  bool enabled = false, edited = false, saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    _configure();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await store.load();
      if (mounted && !edited) {
        setState(() => preference = value);
      }
    } catch (failure) {
      if (mounted) {
        setState(() => error = '$failure');
      }
    }
  }

  void _configure() {
    widget.controller.nextTimerDuration = enabled
        ? Duration(minutes: preference.minutes)
        : null;
    widget.controller.nextTimerVibrate = preference.vibrate;
  }

  Future<void> _edit() async {
    // Local form state avoids a text-controller lifetime tied to dialog animation.
    var minutes = '${preference.minutes}';
    var vibrate = preference.vibrate;
    final minutesFieldKey = GlobalKey<FormFieldState<String>>();
    final key = GlobalKey<FormState>();
    final value = await showDialog<SessionTimerPreference>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Session timer'),
          content: SingleChildScrollView(
            child: Form(
              key: key,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    key: minutesFieldKey,
                    initialValue: minutes,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Minutes (1–1440)',
                    ),
                    onChanged: (value) => minutes = value,
                    validator: (value) {
                      final n = int.tryParse(value ?? '');
                      return n == null || n < 1 || n > 1440
                          ? 'Enter 1–1440 minutes'
                          : null;
                    },
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final duration in [5, 10, 20, 30, 60])
                        ActionChip(
                          label: Text('$duration min'),
                          onPressed: () {
                            minutes = '$duration';
                            minutesFieldKey.currentState?.didChange(minutes);
                          },
                        ),
                    ],
                  ),
                  SwitchListTile(
                    title: const Text('Vibrate at completion'),
                    value: vibrate,
                    onChanged: (value) => update(() => vibrate = value),
                  ),
                  const Text(
                    'A brief chime plays at completion. Recording continues until you press Stop.',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (key.currentState!.validate()) {
                  Navigator.pop(
                    context,
                    SessionTimerPreference(
                      minutes: int.parse(minutes),
                      vibrate: vibrate,
                    ),
                  );
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (value == null || !mounted) {
      return;
    }
    setState(() {
      edited = true;
      saving = true;
      preference = value;
      error = null;
    });
    _configure();
    try {
      await store.save(value);
    } catch (failure) {
      if (mounted) {
        setState(() => error = '$failure');
      }
    } finally {
      if (mounted) {
        setState(() => saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SwitchListTile(
        title: InkWell(
          onTap: saving ? null : _edit,
          child: const Text('Optional session timer'),
        ),
        subtitle: InkWell(
          onTap: saving ? null : _edit,
          child: Text('${preference.minutes} minutes · pauses with recording'),
        ),
        value: enabled,
        onChanged: saving
            ? null
            : (value) {
                setState(() {
                  edited = true;
                  enabled = value;
                });
                _configure();
              },
        secondary: IconButton(
          tooltip: 'Customize timer',
          onPressed: saving ? null : _edit,
          icon: const Icon(Icons.timer_outlined),
        ),
      ),
      if (error != null) Text('Timer preference: $error'),
    ],
  );
}
