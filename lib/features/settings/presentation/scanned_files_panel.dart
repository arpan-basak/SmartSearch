import 'dart:async';

import 'package:flutter/material.dart';
import 'package:smart_search_app/core/platform/search_platform.dart';

class ScannedFilesPanel extends StatefulWidget {
  const ScannedFilesPanel({super.key});
  @override
  State<ScannedFilesPanel> createState() => _ScannedFilesPanelState();
}

class _ScannedFilesPanelState extends State<ScannedFilesPanel> {
  Timer? _timer;
  Map<dynamic, dynamic>? _status;
  bool _busy = false;
  bool _loaded = false;
  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
    if (!mounted) return;
    await _refresh();
    if (mounted) {
      _timer = Timer.periodic(
          const Duration(seconds: 3), (_) => unawaited(_refresh()));
    }
  }

  Future<void> _refresh() async {
    if (_busy) return;
    _busy = true;
    try {
      final status = await searchPlatformChannel
          .invokeMethod<Map>('getDocumentIndexStatus');
      if (mounted) setState(() => _status = status);
    } catch (_) {
    } finally {
      _busy = false;
      if (mounted) setState(() => _loaded = true);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scanned = int.tryParse('${_status?['indexed'] ?? 0}') ?? 0;
    final total = int.tryParse('${_status?['total'] ?? 0}') ?? 0;
    final complete = _status?['complete'] == true;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Scanned files: $scanned of $total'),
        const SizedBox(height: 8),
        LinearProgressIndicator(
            value: total > 0 ? (scanned / total).clamp(0.0, 1.0) : 0),
        const SizedBox(height: 6),
        Text(_status == null
            ? (_loaded ? 'Scan status unavailable' : 'Loading scan status…')
            : complete
                ? 'Files ready to search'
                : switch (_status?['state']) {
                    'running' => 'Reading files on this phone',
                    'paused_for_search' => 'Scanning paused while you search',
                    'waiting_permission' => 'File access permission is needed',
                    'waiting_for_idle_charging' => 'Waiting for idle charging',
                    'waiting_for_idle' => 'Waiting for the phone to be idle',
                    'waiting_for_charging' => 'Waiting for a charger',
                    'scheduled' => 'Scanning is scheduled',
                    'interrupted' ||
                    'recovering' ||
                    'retrying' =>
                      'Resuming file scanning',
                    'paused_memory' => 'Large-file scan paused',
                    _ => 'Preparing file scan',
                  }),
      ]),
    );
  }
}
