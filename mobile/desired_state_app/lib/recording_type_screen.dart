import 'package:flutter/material.dart';

import 'recording_types.dart';

class RecordingTypeScreen extends StatefulWidget {
  const RecordingTypeScreen({super.key, required this.store});
  final RecordingTypeStore store;
  @override
  State<RecordingTypeScreen> createState() => _RecordingTypeScreenState();
}

class _RecordingTypeScreenState extends State<RecordingTypeScreen> {
  late Future<Map<String, RecordingType>> _types = widget.store.list();
  Future<void> _edit([RecordingType? type]) async {
    final name = TextEditingController(text: type?.name ?? '');
    final definition = TextEditingController(text: type?.definition ?? '');
    try {
      final values = await showDialog<(String, String)>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            type == null ? 'Add recording type' : 'Edit recording type',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                TextField(
                  controller: definition,
                  maxLength: 2000,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Definition or intended use',
                  ),
                ),
                const Text(
                  'A new definition revision applies to future recordings. Saved sessions retain their original definition.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, (name.text, definition.text)),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (values == null) {
        return;
      }
      await widget.store.save(values.$1, values.$2, id: type?.id);
      if (mounted) {
        setState(() => _types = widget.store.list());
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      // Allow the dialog's exit transition to finish before disposing its fields.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      name.dispose();
      definition.dispose();
    }
  }

  Future<void> _archive(RecordingType type) async {
    try {
      await widget.store.save(
        type.name,
        type.definition,
        id: type.id,
        archived: !type.archived,
      );
      if (mounted) {
        setState(() => _types = widget.store.list());
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Recording types'),
      actions: [
        IconButton(
          tooltip: 'Add recording type',
          icon: const Icon(Icons.add),
          onPressed: _edit,
        ),
      ],
    ),
    body: FutureBuilder<Map<String, RecordingType>>(
      future: _types,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Phone definitions synchronize to Windows. Same type means the same category; technique, conditions and devices still matter when comparing results.',
              ),
            ),
            for (final type in snapshot.data!.values)
              ListTile(
                title: Text(
                  '${type.name}${type.archived ? ' · archived' : ''}',
                ),
                subtitle: Text(
                  '${type.definition}\n${type.id} · revision ${type.version}',
                ),
                onTap: () => _edit(type),
                trailing: IconButton(
                  tooltip: type.archived ? 'Restore type' : 'Archive type',
                  icon: Icon(
                    type.archived
                        ? Icons.unarchive_outlined
                        : Icons.archive_outlined,
                  ),
                  onPressed: () => _archive(type),
                ),
              ),
          ],
        );
      },
    ),
  );
}
