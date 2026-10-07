import 'package:flutter/material.dart';

import 'eeg_bands.dart';
import 'session_controller.dart';

class EegQualityPanel extends StatelessWidget {
  const EegQualityPanel({super.key, required this.controller});
  final SessionController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final muse = controller.museAthena;
      final channels = muse.eegHistory.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final qualities = {
        for (final channel in channels)
          channel.key: assessEegWindow(channel.value, muse.eegRate),
      };
      final passed = qualities.values.where((q) => q.usable).length;
      final age = muse.lastSamplesAt == null
          ? null
          : DateTime.now().difference(muse.lastSamplesAt!).inSeconds;
      return ExpansionTile(
        title: const Text('EEG signal check'),
        subtitle: Text(
          muse.fresh
              ? '$passed/${channels.length} channels usable · updated ${age ?? 0}s ago'
              : 'Waiting or stale · ${age == null ? 'no samples' : 'last samples ${age}s ago'}',
        ),
        children: [
          if (channels.isEmpty)
            const ListTile(
              title: Text('Connect Muse to check channel quality.'),
            ),
          for (final channel in channels)
            ListTile(
              leading: Icon(
                muse.fresh && qualities[channel.key]!.usable
                    ? Icons.check_circle
                    : Icons.warning_amber,
                color: muse.fresh && qualities[channel.key]!.usable
                    ? Colors.green
                    : Colors.orange,
              ),
              title: Text('Channel ${channel.key}'),
              subtitle: Text(
                !muse.fresh
                    ? 'Stale — reconnect/check streaming'
                    : qualities[channel.key]!.reason ?? 'Usable window',
              ),
            ),
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Adjust the headband gently, stay still and wait a few seconds. Large changes can be movement or poor contact. This checks sample artifacts, not electrode impedance. Band-share plots require every channel to pass; failed windows remain saved as raw EEG when EEG recording is enabled.',
            ),
          ),
        ],
      );
    },
  );
}
