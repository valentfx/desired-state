import 'dart:async';

import 'package:flutter/material.dart';

import 'quick_markers.dart';
import 'session_controller.dart';

/// Full-screen editor keeps Save above the keyboard and content scrollable.
class MarkerTextEditor extends StatefulWidget {
  const MarkerTextEditor({
    super.key,
    required this.title,
    required this.label,
    required this.save,
    this.initial = '',
    this.maxLength = 48,
  });
  final String title;
  final String label;
  final String initial;
  final int maxLength;
  final Future<void> Function(String) save;
  @override
  State<MarkerTextEditor> createState() => _MarkerTextEditorState();
}

class _MarkerTextEditorState extends State<MarkerTextEditor> {
  late final _text = TextEditingController(text: widget.initial);
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_text.text.trim().isEmpty) {
      setState(() => _error = 'Enter ${widget.label.toLowerCase()}.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.save(_text.text);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title),
      actions: [
        TextButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _text,
            autofocus: true,
            enabled: !_saving,
            maxLength: widget.maxLength,
            maxLines: widget.maxLength == 48 ? 1 : 6,
            decoration: InputDecoration(
              labelText: widget.label,
              errorText: _error,
            ),
            onSubmitted: widget.maxLength == 48 ? (_) => _save() : null,
          ),
        ],
      ),
    ),
  );
}

class QuickMarkerManager extends StatelessWidget {
  const QuickMarkerManager({super.key, required this.store});
  final QuickMarkerStore store;
  Future<void> _edit(BuildContext context, [QuickMarkerDefinition? item]) =>
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => MarkerTextEditor(
            title: item == null ? 'Add quick marker' : 'Rename quick marker',
            label: 'Label',
            initial: item?.label ?? '',
            save: (label) =>
                item == null ? store.add(label) : store.rename(item.id, label),
          ),
        ),
      );
  Future<void> _change(BuildContext context, Future<void> operation) async {
    try {
      await operation;
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Quick markers'),
        actions: [
          IconButton(
            tooltip: 'Add quick marker',
            onPressed: store.ready && !store.saving
                ? () => _edit(context)
                : null,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Most-used buttons appear first. Arrows set the order for equal usage counts. Renaming or removing a button keeps past events unchanged.',
              ),
            ),
            if (!store.ready) Text(store.error ?? 'Loading markers…'),
            if (store.ready && store.items.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No quick markers. Tap + to add one.'),
              ),
            for (final (index, item) in store.items.indexed)
              ListTile(
                key: ValueKey(item.id),
                title: Text(item.label),
                subtitle: Text(
                  'Used ${item.uses} times${item.activityId == null ? "" : " · activity"}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Move ${item.label} up',
                      icon: const Icon(Icons.arrow_upward),
                      onPressed: store.saving || index == 0
                          ? null
                          : () => _change(context, store.move(item.id, -1)),
                    ),
                    IconButton(
                      tooltip: 'Move ${item.label} down',
                      icon: const Icon(Icons.arrow_downward),
                      onPressed: store.saving || index == store.items.length - 1
                          ? null
                          : () => _change(context, store.move(item.id, 1)),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Edit ${item.label}',
                      enabled: !store.saving,
                      onSelected: (action) {
                        if (action == 'rename') {
                          _edit(context, item);
                        } else {
                          _change(context, store.remove(item.id));
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'rename', child: Text('Rename')),
                        PopupMenuItem(value: 'remove', child: Text('Remove')),
                      ],
                    ),
                  ],
                ),
              ),
            if (store.ready)
              ExpansionTile(
                title: const Text('Add activity buttons'),
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final activity in activityMarkerCatalog.where(
                        (a) => !store.items.any(
                          (m) => m.activityId == a.activityId || m.id == a.id,
                        ),
                      ))
                        ActionChip(
                          label: Text(activity.label),
                          onPressed: store.saving
                              ? null
                              : () => _change(
                                  context,
                                  store.addActivity(activity),
                                ),
                        ),
                    ],
                  ),
                ],
              ),
          ],
        ),
      ),
    ),
  );
}

Future<void> showMarkerNote(
  BuildContext context,
  SessionController controller,
  RecordedMarker marker,
) => Navigator.push(
  context,
  MaterialPageRoute<void>(
    builder: (_) => MarkerTextEditor(
      title: 'Note: ${marker.label}',
      label: 'Note',
      maxLength: 4000,
      save: (note) => controller.addMarkerNote(marker, note),
    ),
  ),
);

class MarkerEventsScreen extends StatelessWidget {
  const MarkerEventsScreen({super.key, required this.controller});
  final SessionController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Recording events')),
      body: SafeArea(
        child: ListView(
          children: [
            if (controller.recordedMarkers.isEmpty)
              const ListTile(title: Text('No marked events yet.')),
            for (final marker in controller.recordedMarkers.reversed)
              ListTile(
                title: Text(marker.label),
                subtitle: Text(
                  '${marker.timestamp.toLocal()}\n${(controller.markerNotes[marker.id] ?? []).join('\n')}',
                ),
                trailing: IconButton(
                  tooltip: 'Add note to ${marker.label}',
                  icon: const Icon(Icons.note_add_outlined),
                  onPressed: () => showMarkerNote(context, controller, marker),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class QuickMarkerBar extends StatefulWidget {
  const QuickMarkerBar({
    super.key,
    required this.controller,
    this.compact = false,
    this.closeAfterRecord = false,
  });
  final bool compact;
  final bool closeAfterRecord;
  final SessionController controller;
  @override
  State<QuickMarkerBar> createState() => _QuickMarkerBarState();
}

class _QuickMarkerBarState extends State<QuickMarkerBar> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.quickMarkers.load());
  }

  Future<void> _record(QuickMarkerDefinition item) async {
    try {
      final marker = await widget.controller.markQuickMarker(item);
      if (!mounted || marker == null) return;
      final messenger = ScaffoldMessenger.of(context);
      final navigator = Navigator.of(context);
      final controller = widget.controller;
      messenger.removeCurrentSnackBar();
      if (widget.closeAfterRecord) navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: const Text('Event saved'),
          action: SnackBarAction(
            label: 'Add note',
            onPressed: () =>
                showMarkerNote(navigator.context, controller, marker),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save marker: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final store = controller.quickMarkers;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => widget.compact
          ? Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text('Add event'),
                    onPressed:
                        store.ready &&
                            controller.sessionLogger != null &&
                            !controller.busy
                        ? () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => Scaffold(
                                appBar: AppBar(title: const Text('Add event')),
                                body: SafeArea(
                                  child: SingleChildScrollView(
                                    child: QuickMarkerBar(
                                      controller: controller,
                                      closeAfterRecord: true,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          )
                        : null,
                  ),
                ),
                IconButton(
                  tooltip: 'More markers and events',
                  icon: const Icon(Icons.more_horiz),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: const Text('Markers & events')),
                        body: SingleChildScrollView(
                          child: QuickMarkerBar(controller: controller),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(child: Text('Quick markers')),
                    TextButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              MarkerEventsScreen(controller: controller),
                        ),
                      ),
                      child: Text(
                        'Events (${controller.recordedMarkers.length})',
                      ),
                    ),
                    IconButton(
                      tooltip: 'Manage quick markers',
                      onPressed: store.ready
                          ? () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    QuickMarkerManager(store: store),
                              ),
                            )
                          : null,
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  ],
                ),
                if (!store.ready) ...[
                  Text(store.error ?? 'Loading quick markers…'),
                  if (store.error != null)
                    TextButton(
                      onPressed: store.retryLoad,
                      child: const Text('Retry loading markers'),
                    ),
                ] else if (store.items.isEmpty)
                  const Text('Add buttons with Manage quick markers.')
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final item in store.items)
                        FilledButton.tonal(
                          onPressed:
                              controller.sessionLogger != null &&
                                  !controller.busy
                              ? () => _record(item)
                              : null,
                          child: Text(item.label),
                        ),
                    ],
                  ),
              ],
            ),
    );
  }
}
