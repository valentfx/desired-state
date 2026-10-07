import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'backend_upload.dart';
import 'upload_status.dart';

class BackendUploadScreen extends StatefulWidget {
  const BackendUploadScreen({
    super.key,
    required this.directory,
    required this.sessionId,
  });
  final Directory directory;
  final String sessionId;
  @override
  State<BackendUploadScreen> createState() => _BackendUploadScreenState();
}

class _BackendUploadScreenState extends State<BackendUploadScreen> {
  bool _busy = false, _success = false;
  String _message = 'Ready to upload this completed session.';
  String? _receipt;
  UploadProgress? _progress;
  UploadControl? _control;
  UploadSnapshot? _pausedSnapshot;

  @override
  void dispose() {
    _control?.cancelled = true;
    if (!_busy && _pausedSnapshot != null) {
      unawaited(_pausedSnapshot!.dispose().catchError((Object _) {}));
      _pausedSnapshot = null;
    }
    super.dispose();
  }

  Future<void> _upload() async {
    if (_busy) return;
    final control = UploadControl();
    _control = control;
    setState(() {
      _busy = true;
      _success = false;
      _progress = null;
      _message = _pausedSnapshot == null
          ? 'Preparing lossless compressed snapshot and calculating file hashes…'
          : 'Resuming the prepared snapshot from server offsets…';
    });
    UploadSnapshot? snapshot;
    HttpUploadApi? api;
    try {
      await writeUploadState(widget.directory, widget.sessionId, 'uploading');
      final token = await readWindowsUploadToken();
      control.check();
      snapshot =
          _pausedSnapshot ??
          await snapshotUpload(widget.directory.path, compress: true);
      _pausedSnapshot = snapshot;
      control.check();
      if (snapshot.sessionId != widget.sessionId) {
        throw const FormatException('Selected session identity changed');
      }
      api = HttpUploadApi(token);
      final receipt = await BackendUploader(api).upload(
        snapshot,
        control: control,
        onProgress: (value) {
          if (mounted) {
            setState(() {
              _progress = value;
              _message = 'Uploading ${value.file}';
            });
          }
        },
      );
      // Receipts sit outside the session directory and never contain credentials.
      final folder = Directory(
        '${widget.directory.parent.parent.path}/upload-receipts',
      );
      await folder.create(recursive: true);
      final file = File(
        '${folder.path}/${widget.sessionId}-${DateTime.now().toUtc().microsecondsSinceEpoch}.json',
      );
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(receipt),
        flush: true,
      );
      if (mounted) {
        setState(() {
          _success = true;
          _receipt = file.path;
          _message =
              'Verified ${snapshot!.files.length} files. Already stored: ${receipt['already_stored_files']} files. New data transferred: ${((receipt['transferred_bytes'] as int) / 1048576).toStringAsFixed(2)} MB. Server storage: ${((receipt['stored_bytes'] as int) / 1048576).toStringAsFixed(2)} MB. Local originals retained.';
        });
      }
    } catch (e) {
      try {
        await writeUploadState(
          widget.directory,
          widget.sessionId,
          e is UploadCancelled ? 'paused' : 'failed',
        );
      } catch (_) {
        // Reporting failure must not hide the original upload error.
      }
      if (mounted) setState(() => _message = '$e');
    } finally {
      api?.close();
      if (snapshot != null && (!control.cancelled || !mounted)) {
        _pausedSnapshot = null;
        try {
          await snapshot.dispose();
        } catch (_) {
          // A leftover private temporary snapshot is never a verified receipt.
        }
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Upload session')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  widget.sessionId,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Destination: valentfx.com · your private upload account',
                ),
                const SizedBox(height: 12),
                const Text(
                  'Uploads all JSON/JSONL files in this completed session, including sensor logs, notes and state feedback. Temporary space for the original snapshot plus its compressed copy is needed. Local files stay on this PC.',
                ),
                const SizedBox(height: 20),
                Text(_message, key: const Key('backend-upload-message')),
                if (_busy) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: progress == null || progress.total == 0
                        ? null
                        : progress.completed / progress.total,
                  ),
                ],
                if (progress != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Original data accounted for: ${(progress.completed / 1048576).toStringAsFixed(1)} / ${(progress.total / 1048576).toStringAsFixed(1)} MB · ${progress.verified}/${progress.fileCount} files verified',
                  ),
                ],
                if (_receipt != null) ...[
                  const SizedBox(height: 12),
                  SelectableText('Verification receipt: $_receipt'),
                ],
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _upload,
                      icon: const Icon(Icons.cloud_upload_outlined),
                      label: Text(
                        _success
                            ? 'Verify / upload again'
                            : 'Upload selected session',
                      ),
                    ),
                    if (_busy)
                      OutlinedButton(
                        onPressed: _control?.cancelled == true
                            ? null
                            : () {
                                _control!.cancelled = true;
                                setState(
                                  () => _message = 'Pausing after the current file operation…',
                                );
                              },
                        child: const Text('Pause upload'),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                const Text(
                  'Credentials are protected for your Windows login. Run configure_backend_upload.ps1 once before uploading. Retry resumes matching file revisions. Automatic uploads are not enabled in this first test.',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
