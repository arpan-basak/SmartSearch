import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:smart_search_app/core/platform/search_platform.dart';
import 'package:smart_search_app/features/cloud_index/data/cloud_index_api.dart';
import 'package:smart_search_app/features/cloud_index/data/cloud_index_store.dart';
import 'package:smart_search_app/features/cloud_index/data/document_identity.dart';
import 'package:smart_search_app/features/cloud_index/domain/cloud_index_models.dart';

class CloudIndexRepository {
  CloudIndexRepository({
    required this.api,
    CloudIndexStore? store,
    MethodChannel? platform,
  })  : store = store ?? CloudIndexStore(),
        platform = platform ?? searchPlatformChannel;

  final CloudIndexApi api;
  final CloudIndexStore store;
  final MethodChannel platform;
  bool _cancelled = false;

  Future<List<CloudSearchHit>> search(String query) async {
    final settings = await store.loadSettings();
    if (!settings.enabled || settings.paused || !settings.consentGranted) {
      return const <CloudSearchHit>[];
    }
    final encoded = await platform.invokeMethod<String>(
      'getTextEmbedding',
      {'text': query},
    );
    if (encoded == null || encoded.isEmpty) return const <CloudSearchHit>[];
    final bytes = base64Decode(encoded);
    final vector = bytes
        .map((value) => value > 127 ? value - 256 : value)
        .map((value) => value / 127.0)
        .toList(growable: false);
    return api.search(vector);
  }

  Future<List<CloudDocumentLocator>> discoverDocuments() async {
    final raw = await platform.invokeMethod<List<dynamic>>('getDocumentIndex');
    final deviceId = await store.deviceId();
    final existing = await store.loadLocators();
    for (final value in raw ?? const <dynamic>[]) {
      if (value is! Map) continue;
      final row = value.cast<dynamic, dynamic>();
      final hash = '${row['hash'] ?? ''}';
      final path = '${row['path'] ?? ''}';
      if (hash.isEmpty || path.isEmpty) continue;
      final size = int.tryParse('${row['size'] ?? 0}') ?? 0;
      final modified = int.tryParse('${row['modified'] ?? 0}') ?? 0;
      final id = cloudDocumentId(
        deviceId: deviceId,
        fileHash: hash,
        fileSize: size,
        modifiedSeconds: modified,
      );
      existing[id] = CloudDocumentLocator(
        documentId: id,
        localUri: path,
        title: '${row['name'] ?? ''}',
        mimeType: '${row['type'] ?? 'application/octet-stream'}',
        fileHash: hash,
        fileSize: size,
        modifiedSeconds: modified,
        availableOffline: true,
      );
    }
    await store.saveLocators(existing);
    return existing.values.toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  Future<void> saveSelection(Set<String> selected) async {
    final settings = await store.loadSettings();
    await store.saveSettings(settings.copyWith(selectedDocumentIds: selected));
  }

  Future<CloudSyncPhase> preflight(CloudIndexSettings settings) async {
    final raw = await platform
            .invokeMethod<Map<dynamic, dynamic>>('getCloudSyncConditions') ??
        const <dynamic, dynamic>{};
    if (raw['connected'] == false || raw['dataSaver'] == true) {
      return CloudSyncPhase.offline;
    }
    if (settings.wifiOnly && raw['wifi'] != true) {
      return CloudSyncPhase.waitingForWifi;
    }
    if (settings.chargingOnly && raw['charging'] != true) {
      return CloudSyncPhase.waitingForCharging;
    }
    if (raw['poorNetwork'] == true || raw['lowBattery'] == true) {
      return CloudSyncPhase.paused;
    }
    return CloudSyncPhase.preparing;
  }

  Future<void> syncNow({void Function(CloudIndexSettings)? onState}) async {
    _cancelled = false;
    var settings = await store.loadSettings();
    if (!settings.enabled || !settings.consentGranted || settings.paused) {
      return;
    }
    final gate = await preflight(settings);
    if (gate != CloudSyncPhase.preparing) {
      settings = settings.copyWith(phase: gate);
      await store.saveSettings(settings);
      onState?.call(settings);
      return;
    }
    settings = settings.copyWith(
        phase: CloudSyncPhase.preparing, clearLastError: true);
    await store.saveSettings(settings);
    onState?.call(settings);

    try {
      final locators = await store.loadLocators();
      final selected = settings.selectedDocumentIds
          .map((id) => locators[id])
          .whereType<CloudDocumentLocator>()
          .toList();
      if (selected.isEmpty) {
        throw const CloudIndexException(
            'Choose at least one document to sync.');
      }
      final rows = await platform.invokeMethod<List<dynamic>>(
            'getCloudSyncRows',
            {'paths': selected.map((item) => item.localUri).toList()},
          ) ??
          const <dynamic>[];
      final graphRows = await platform.invokeMethod<List<dynamic>>(
            'getCloudGraphRows',
            {'paths': selected.map((item) => item.localUri).toList()},
          ) ??
          const <dynamic>[];
      final byPath = <String, List<Map<dynamic, dynamic>>>{};
      for (final value in rows.whereType<Map>()) {
        final path = '${value['path'] ?? ''}';
        byPath.putIfAbsent(path, () => []).add(value.cast<dynamic, dynamic>());
      }
      final graphByPath = <String, List<Map<dynamic, dynamic>>>{};
      for (final value in graphRows.whereType<Map>()) {
        final path = '${value['path'] ?? ''}';
        graphByPath
            .putIfAbsent(path, () => [])
            .add(value.cast<dynamic, dynamic>());
      }
      final manifest = await store.loadManifest();
      final pending = <Map<String, Object?>>[];
      for (final locator in selected) {
        final revision = cloudRevision(
          fileHash: locator.fileHash,
          fileSize: locator.fileSize,
          modifiedSeconds: locator.modifiedSeconds,
        );
        if (manifest[locator.documentId] == revision) continue;
        final chunks = byPath[locator.localUri] ?? const [];
        if (chunks.isEmpty) continue;
        final encodedChunks = chunks.map((chunk) {
          final index = int.tryParse('${chunk['chunkIndex'] ?? 0}') ?? 0;
          return <String, Object?>{
            'chunkId': '$index',
            'pageNumber': int.tryParse('${chunk['pageStart'] ?? 0}') ?? 0,
            'content': '${chunk['content'] ?? ''}',
            'summary': '${chunk['summary'] ?? ''}',
            'embedding': '${chunk['embedding'] ?? ''}',
          };
        }).toList();
        final graph = graphByPath[locator.localUri] ?? const [];
        final entities = <String, Map<String, Object?>>{};
        final relations = <Map<String, Object?>>[];
        for (final relation in graph) {
          final kind = '${relation['entityType'] ?? 'term'}';
          final label = '${relation['label'] ?? ''}'.trim();
          if (label.isEmpty) continue;
          final entityId =
              cloudGraphId([locator.documentId, kind, label.toLowerCase()]);
          entities[entityId] = {
            'entityId': entityId,
            'label': label,
            'kind': kind,
          };
          final relationType = '${relation['relationship'] ?? 'MENTIONS'}';
          relations.add({
            'relationId':
                cloudGraphId([locator.documentId, entityId, relationType]),
            'entityId': entityId,
            'relationType': relationType,
          });
        }
        for (var chunkOffset = 0;
            chunkOffset < encodedChunks.length;
            chunkOffset += 50) {
          final end = (chunkOffset + 50).clamp(0, encodedChunks.length);
          pending.add({
            'documentId': locator.documentId,
            'title': locator.title,
            'mimeType': locator.mimeType,
            'fileHash': locator.fileHash,
            'fileSize': locator.fileSize,
            'modifiedSeconds': locator.modifiedSeconds,
            'revision': revision,
            'complete': end == encodedChunks.length,
            'chunks': encodedChunks.sublist(chunkOffset, end),
            if (chunkOffset == 0) 'entities': entities.values.toList(),
            if (chunkOffset == 0) 'relations': relations,
          });
        }
      }

      settings = settings.copyWith(phase: CloudSyncPhase.uploading);
      await store.saveSettings(settings);
      onState?.call(settings);
      final deviceId = await store.deviceId();
      for (var offset = 0; offset < pending.length; offset += 4) {
        if (_cancelled) return;
        final batch =
            pending.sublist(offset, (offset + 4).clamp(0, pending.length));
        Object? lastError;
        for (var attempt = 0; attempt < 4; attempt++) {
          try {
            await api.syncBatch(deviceId: deviceId, documents: batch);
            lastError = null;
            break;
          } catch (error) {
            lastError = error;
            if (attempt < 3) {
              await Future<void>.delayed(
                  Duration(milliseconds: 400 * (1 << attempt)));
            }
          }
        }
        if (lastError != null) throw lastError;
        for (final document in batch) {
          if (document['complete'] == true) {
            manifest['${document['documentId']}'] = '${document['revision']}';
          }
        }
        await store.saveManifest(manifest);
      }
      await api.status(); // Verification step before local retention changes.
      if (!settings.keepFullOfflineIndex) {
        await platform.invokeMethod<bool>('removeVerifiedLocalCloudIndex', {
          'paths': selected.map((item) => item.localUri).toList(),
          'budgetBytes': LocalBudgetPolicy(settings.localBudgetMb).bytes,
        });
      }
      settings = settings.copyWith(
        phase: CloudSyncPhase.synced,
        lastSuccessfulSync: DateTime.now(),
        clearLastError: true,
      );
      await store.saveSettings(settings);
      onState?.call(settings);
    } catch (error) {
      settings =
          settings.copyWith(phase: CloudSyncPhase.error, lastError: '$error');
      await store.saveSettings(settings);
      onState?.call(settings);
      rethrow;
    }
  }

  void cancelSync() => _cancelled = true;

  Future<void> deleteCloudIndex() async {
    await api.deleteIndex();
    final current = await store.loadSettings();
    await store.clearCloudState();
    await store.saveSettings(CloudIndexSettings(
      wifiOnly: current.wifiOnly,
      chargingOnly: current.chargingOnly,
      localBudgetMb: current.localBudgetMb,
      keepFullOfflineIndex: current.keepFullOfflineIndex,
    ));
  }

  Future<void> deleteLocalIndex() async {
    await platform.invokeMethod<bool>('deleteLocalDocumentIndex');
  }

  Future<CloudStorageBreakdown> storageBreakdown() async {
    final local = await platform.invokeMethod<Map<dynamic, dynamic>>(
            'getDocumentStorageBreakdown') ??
        const <dynamic, dynamic>{};
    var cloudCount = 0;
    if (api.isConfigured) {
      try {
        final remote = await api.status();
        cloudCount = (remote['documentCount'] as num?)?.toInt() ?? 0;
      } catch (_) {}
    }
    int value(String key) => (local[key] as num?)?.toInt() ?? 0;
    return CloudStorageBreakdown(
      localDocumentIndexBytes: value('documentIndexBytes'),
      localKnowledgeGraphBytes: value('knowledgeGraphBytes'),
      embeddingBytes: value('embeddingBytes'),
      ocrChunkBytes: value('ocrChunkBytes'),
      previewCacheBytes: value('previewCacheBytes'),
      localDocumentCount: value('documentCount'),
      cloudDocumentCount: cloudCount,
    );
  }
}
