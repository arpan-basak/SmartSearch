import 'dart:async';

import 'package:flutter/material.dart';
import 'package:smart_search_app/design_system/nexa_theme.dart';
import 'package:smart_search_app/features/account/data/account_sync.dart';
import 'package:smart_search_app/features/cloud_index/data/cloud_index_api.dart';
import 'package:smart_search_app/features/cloud_index/data/cloud_index_repository.dart';
import 'package:smart_search_app/features/cloud_index/domain/cloud_index_models.dart';

enum _DisableChoice { pause, localOnly, deleteCloud }

class CloudIndexSettingsScreen extends StatefulWidget {
  const CloudIndexSettingsScreen({
    super.key,
    required this.accountSync,
    this.repository,
  });

  final AccountSync? accountSync;
  final CloudIndexRepository? repository;

  @override
  State<CloudIndexSettingsScreen> createState() =>
      _CloudIndexSettingsScreenState();
}

class _CloudIndexSettingsScreenState extends State<CloudIndexSettingsScreen> {
  late final CloudIndexRepository _repository;
  CloudIndexSettings _settings = const CloudIndexSettings();
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ??
        CloudIndexRepository(
          api: CloudIndexApi(
            tokenProvider: () async => widget.accountSync?.getIdToken(),
          ),
        );
    unawaited(_load());
  }

  Future<void> _load() async {
    final settings = await _repository.store.loadSettings();
    if (mounted) {
      setState(() {
        _settings = settings;
        _loading = false;
      });
    }
  }

  Future<void> _save(CloudIndexSettings value) async {
    await _repository.store.saveSettings(value);
    if (mounted) setState(() => _settings = value);
  }

  Future<bool> _showConsent() async {
    return await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          builder: (sheetContext) => SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Enable Apex Cloud Sync?',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  const Text(
                    'Cloud sync can reduce phone storage used by the searchable index. Original documents remain on this phone by default. OCR text, summaries, embeddings, and knowledge-graph data for only the documents you choose may be stored in Cloudflare for search. Full cloud search needs internet.',
                    style: TextStyle(height: 1.45),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'You can pause sync, keep the remote index, or permanently delete it later. This is not end-to-end encrypted because the search service must process OCR text.',
                    style: TextStyle(
                        color: NexaColors.textSecondary, height: 1.45),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    key: const Key('cloud-consent-confirm'),
                    onPressed: () => Navigator.pop(sheetContext, true),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52)),
                    child: const Text('I understand and enable Cloud Sync'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(sheetContext, false),
                    style: TextButton.styleFrom(
                        minimumSize: const Size.fromHeight(48)),
                    child: const Text('Not now'),
                  ),
                ],
              ),
            ),
          ),
        ) ??
        false;
  }

  Future<Set<String>?> _chooseDocuments() async {
    setState(() => _busy = true);
    try {
      final documents = await _repository.discoverDocuments();
      if (!mounted) return null;
      var selected = Set<String>.from(_settings.selectedDocumentIds);
      return showModalBottomSheet<Set<String>>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) => StatefulBuilder(
          builder: (context, setSheetState) => SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.76,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 18, 22, 8),
                    child: Row(children: [
                      Expanded(
                        child: Text('Choose documents to sync',
                            style: Theme.of(context).textTheme.titleLarge),
                      ),
                      Text('${selected.length} selected'),
                    ]),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 22),
                    child: Text(
                      'Nothing is uploaded automatically. Select only the indexed files you want in your private cloud index.',
                      style: TextStyle(color: NexaColors.textSecondary),
                    ),
                  ),
                  const Divider(height: 24),
                  Expanded(
                    child: documents.isEmpty
                        ? const Center(
                            child: Text('No completed local documents yet.'))
                        : ListView.builder(
                            itemCount: documents.length,
                            itemBuilder: (context, index) {
                              final document = documents[index];
                              return CheckboxListTile(
                                value: selected.contains(document.documentId),
                                title: Text(document.title),
                                subtitle: Text(document.mimeType),
                                onChanged: (checked) => setSheetState(() {
                                  if (checked == true) {
                                    selected.add(document.documentId);
                                  } else {
                                    selected.remove(document.documentId);
                                  }
                                }),
                              );
                            },
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(18),
                    child: FilledButton(
                      key: const Key('cloud-document-selection-save'),
                      onPressed: selected.isEmpty
                          ? null
                          : () => Navigator.pop(sheetContext, selected),
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52)),
                      child: const Text('Use selected documents'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enable() async {
    if (widget.repository == null && widget.accountSync?.currentUser == null) {
      _message('Sign in to your Apex AI account before enabling Cloud Sync.');
      return;
    }
    if (!await _showConsent()) return;
    final selected = await _chooseDocuments();
    if (selected == null || selected.isEmpty) return;
    await _save(_settings.copyWith(
      enabled: true,
      consentGranted: true,
      paused: false,
      selectedDocumentIds: selected,
      phase: CloudSyncPhase.preparing,
      clearLastError: true,
    ));
  }

  Future<void> _disable() async {
    final choice = await showModalBottomSheet<_DisableChoice>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            key: const Key('cloud-disable-pause'),
            leading: const Icon(Icons.pause_circle_outline),
            title: const Text('Pause cloud sync'),
            subtitle: const Text('Retain the existing cloud index.'),
            onTap: () => Navigator.pop(sheetContext, _DisableChoice.pause),
          ),
          ListTile(
            key: const Key('cloud-disable-local-only'),
            leading: const Icon(Icons.phone_android_outlined),
            title: const Text('Keep local data only'),
            subtitle:
                const Text('Stop future uploads; remote data is retained.'),
            onTap: () => Navigator.pop(sheetContext, _DisableChoice.localOnly),
          ),
          ListTile(
            key: const Key('cloud-disable-delete'),
            leading: const Icon(Icons.delete_forever_outlined,
                color: NexaColors.error),
            title: const Text('Delete cloud index permanently'),
            subtitle: const Text(
                'Delete vectors, chunks, graph data, and sync state.'),
            onTap: () =>
                Navigator.pop(sheetContext, _DisableChoice.deleteCloud),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (choice == null) return;
    switch (choice) {
      case _DisableChoice.pause:
        _repository.cancelSync();
        await _save(_settings.copyWith(
            enabled: true, paused: true, phase: CloudSyncPhase.paused));
        return;
      case _DisableChoice.localOnly:
        _repository.cancelSync();
        await _save(_settings.copyWith(
            enabled: false, paused: false, phase: CloudSyncPhase.disabled));
        return;
      case _DisableChoice.deleteCloud:
        await _confirmDeleteCloud();
        return;
    }
  }

  Future<bool> _strongConfirmation(String title, String detail) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(detail),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel')),
              FilledButton(
                key: const Key('cloud-destructive-confirm'),
                style:
                    FilledButton.styleFrom(backgroundColor: NexaColors.error),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Delete permanently'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _confirmDeleteCloud() async {
    if (!await _strongConfirmation('Delete cloud index?',
        'This permanently deletes cloud vectors, OCR chunks, summaries, graph data, metadata, and sync state. Original files on your phone are not deleted.')) {
      return;
    }
    await _runBusy(_repository.deleteCloudIndex,
        success: 'Cloud index deleted.');
    await _load();
  }

  Future<void> _confirmDeleteLocal() async {
    if (!await _strongConfirmation('Delete local index?',
        'This deletes local OCR text, embeddings, graph data, and previews. Original documents are not deleted. Local search can rebuild the index later.')) {
      return;
    }
    await _runBusy(_repository.deleteLocalIndex,
        success: 'Local index deleted.');
  }

  Future<void> _confirmDeleteBoth() async {
    if (!await _strongConfirmation('Delete both indexes?',
        'This permanently deletes the cloud index and removes the local generated index. Original documents remain on your phone.')) {
      return;
    }
    await _runBusy(() async {
      await _repository.deleteCloudIndex();
      await _repository.deleteLocalIndex();
    }, success: 'Local and cloud indexes deleted.');
    await _load();
  }

  Future<void> _runBusy(Future<void> Function() operation,
      {String? success}) async {
    setState(() => _busy = true);
    try {
      await operation();
      if (success != null) _message(success);
    } catch (error) {
      _message('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    await _runBusy(
      () => _repository.syncNow(onState: (settings) {
        if (mounted) setState(() => _settings = settings);
      }),
      success: 'Cloud index is up to date.',
    );
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(children: [
              NexaPageHeader(
                title: 'Apex Cloud Sync',
                subtitle: 'Optional hybrid document index',
                onBack: () => Navigator.pop(context),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
                        children: [
                          _panel([
                            SwitchListTile(
                              key: const Key('cloud-sync-toggle'),
                              secondary: const Icon(Icons.cloud_outlined),
                              title: const Text('Cloud Data Sync'),
                              subtitle: Text(_settings.phase.label),
                              value: _settings.enabled && !_settings.paused,
                              onChanged: _busy
                                  ? null
                                  : (enabled) => unawaited(
                                      enabled ? _enable() : _disable()),
                            ),
                          ]),
                          const SizedBox(height: 22),
                          const NexaSectionLabel('Sync conditions'),
                          const SizedBox(height: 9),
                          _panel([
                            SwitchListTile(
                              title: const Text('Sync on Wi-Fi only'),
                              value: _settings.wifiOnly,
                              onChanged: (value) => unawaited(
                                  _save(_settings.copyWith(wifiOnly: value))),
                            ),
                            SwitchListTile(
                              title: const Text('Sync only while charging'),
                              value: _settings.chargingOnly,
                              onChanged: (value) => unawaited(_save(
                                  _settings.copyWith(chargingOnly: value))),
                            ),
                            SwitchListTile(
                              title: const Text('Keep full offline index'),
                              subtitle: const Text(
                                  'Turn off only after a verified cloud upload.'),
                              value: _settings.keepFullOfflineIndex,
                              onChanged: (value) => unawaited(_save(_settings
                                  .copyWith(keepFullOfflineIndex: value))),
                            ),
                            ListTile(
                              title: const Text('Local index storage budget'),
                              subtitle: Slider(
                                key: const Key('cloud-local-budget'),
                                min: 50,
                                max: 1000,
                                divisions: 19,
                                label: '${_settings.localBudgetMb} MB',
                                value: _settings.localBudgetMb.toDouble(),
                                onChanged: (value) => setState(() => _settings =
                                    _settings.copyWith(
                                        localBudgetMb:
                                            (value / 50).round() * 50)),
                                onChangeEnd: (_) => unawaited(_save(_settings)),
                              ),
                              trailing: Text('${_settings.localBudgetMb} MB'),
                            ),
                          ]),
                          const SizedBox(height: 22),
                          const NexaSectionLabel('Documents and storage'),
                          const SizedBox(height: 9),
                          _panel([
                            ListTile(
                              title: const Text('Documents selected'),
                              subtitle: Text(
                                  '${_settings.selectedDocumentIds.length} documents'),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: _busy
                                  ? null
                                  : () async {
                                      final selected = await _chooseDocuments();
                                      if (selected != null) {
                                        await _save(_settings.copyWith(
                                            selectedDocumentIds: selected));
                                      }
                                    },
                            ),
                            ListTile(
                              title: const Text('Storage breakdown'),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                  builder: (_) => CloudStorageBreakdownScreen(
                                      repository: _repository),
                                ),
                              ),
                            ),
                          ]),
                          if (_settings.lastSuccessfulSync != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              'Last successful sync: ${_settings.lastSuccessfulSync!.toLocal()}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                          if (_settings.lastError?.isNotEmpty == true) ...[
                            const SizedBox(height: 12),
                            Text(_settings.lastError!,
                                style:
                                    const TextStyle(color: NexaColors.error)),
                          ],
                          const SizedBox(height: 22),
                          FilledButton.icon(
                            key: const Key('cloud-sync-now'),
                            onPressed:
                                _busy || !_settings.enabled || _settings.paused
                                    ? null
                                    : _syncNow,
                            icon: const Icon(Icons.sync_rounded),
                            label: Text(_busy ? 'Working…' : 'Sync now'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () => unawaited(_save(_settings.copyWith(
                                    enabled: true,
                                    paused: true,
                                    phase: CloudSyncPhase.paused))),
                            icon: const Icon(Icons.pause_rounded),
                            label: const Text('Pause sync'),
                          ),
                          const SizedBox(height: 24),
                          OutlinedButton(
                            onPressed: _busy ? null : _confirmDeleteCloud,
                            child: const Text('Delete cloud index'),
                          ),
                          OutlinedButton(
                            onPressed: _busy ? null : _confirmDeleteLocal,
                            child: const Text('Delete local index'),
                          ),
                          FilledButton(
                            style: FilledButton.styleFrom(
                                backgroundColor: NexaColors.error),
                            onPressed: _busy ? null : _confirmDeleteBoth,
                            child:
                                const Text('Delete both local and cloud index'),
                          ),
                        ],
                      ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _panel(List<Widget> children) => DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? NexaColors.raised
              : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: Column(
          children: [
            for (var index = 0; index < children.length; index++) ...[
              children[index],
              if (index != children.length - 1)
                const Divider(indent: 16, endIndent: 16),
            ]
          ],
        ),
      );
}

class CloudStorageBreakdownScreen extends StatelessWidget {
  const CloudStorageBreakdownScreen({super.key, required this.repository});
  final CloudIndexRepository repository;

  String _bytes(int value) {
    if (value >= 1024 * 1024) {
      return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (value >= 1024) return '${(value / 1024).toStringAsFixed(0)} KB';
    return '$value B';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Storage breakdown')),
        body: FutureBuilder<CloudStorageBreakdown>(
          future: repository.storageBreakdown(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final data = snapshot.data!;
            final rows = <(String, String)>[
              ('Local document index', _bytes(data.localDocumentIndexBytes)),
              ('Local knowledge graph', _bytes(data.localKnowledgeGraphBytes)),
              ('Embeddings', _bytes(data.embeddingBytes)),
              ('OCR and chunk text', _bytes(data.ocrChunkBytes)),
              ('Previews and cache', _bytes(data.previewCacheBytes)),
              ('Local indexed documents', '${data.localDocumentCount}'),
              ('Cloud-synced documents', '${data.cloudDocumentCount}'),
            ];
            return ListView(
              padding: const EdgeInsets.all(20),
              children: rows
                  .map((row) => ListTile(
                        title: Text(row.$1),
                        trailing: Text(row.$2),
                      ))
                  .toList(),
            );
          },
        ),
      );
}
