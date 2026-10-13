import 'package:flutter/material.dart';
import 'package:smart_search_app/features/search/models/search_result.dart';

enum CloudSyncPhase {
  disabled,
  consentRequired,
  preparing,
  uploading,
  synced,
  paused,
  offline,
  waitingForWifi,
  waitingForCharging,
  error,
}

extension CloudSyncPhaseLabel on CloudSyncPhase {
  String get label => switch (this) {
        CloudSyncPhase.disabled => 'Cloud Sync disabled',
        CloudSyncPhase.consentRequired => 'Consent required',
        CloudSyncPhase.preparing => 'Preparing',
        CloudSyncPhase.uploading => 'Uploading',
        CloudSyncPhase.synced => 'Synced',
        CloudSyncPhase.paused => 'Paused',
        CloudSyncPhase.offline => 'Offline',
        CloudSyncPhase.waitingForWifi => 'Waiting for Wi-Fi',
        CloudSyncPhase.waitingForCharging => 'Waiting for charging',
        CloudSyncPhase.error => 'Error',
      };
}

class CloudIndexSettings {
  const CloudIndexSettings({
    this.enabled = false,
    this.consentGranted = false,
    this.paused = false,
    this.wifiOnly = true,
    this.chargingOnly = true,
    this.keepFullOfflineIndex = true,
    this.localBudgetMb = 250,
    this.selectedDocumentIds = const <String>{},
    this.phase = CloudSyncPhase.disabled,
    this.lastSuccessfulSync,
    this.lastError,
  });

  final bool enabled;
  final bool consentGranted;
  final bool paused;
  final bool wifiOnly;
  final bool chargingOnly;
  final bool keepFullOfflineIndex;
  final int localBudgetMb;
  final Set<String> selectedDocumentIds;
  final CloudSyncPhase phase;
  final DateTime? lastSuccessfulSync;
  final String? lastError;

  CloudIndexSettings copyWith({
    bool? enabled,
    bool? consentGranted,
    bool? paused,
    bool? wifiOnly,
    bool? chargingOnly,
    bool? keepFullOfflineIndex,
    int? localBudgetMb,
    Set<String>? selectedDocumentIds,
    CloudSyncPhase? phase,
    DateTime? lastSuccessfulSync,
    String? lastError,
    bool clearLastError = false,
  }) =>
      CloudIndexSettings(
        enabled: enabled ?? this.enabled,
        consentGranted: consentGranted ?? this.consentGranted,
        paused: paused ?? this.paused,
        wifiOnly: wifiOnly ?? this.wifiOnly,
        chargingOnly: chargingOnly ?? this.chargingOnly,
        keepFullOfflineIndex: keepFullOfflineIndex ?? this.keepFullOfflineIndex,
        localBudgetMb: localBudgetMb ?? this.localBudgetMb,
        selectedDocumentIds: selectedDocumentIds ?? this.selectedDocumentIds,
        phase: phase ?? this.phase,
        lastSuccessfulSync: lastSuccessfulSync ?? this.lastSuccessfulSync,
        lastError: clearLastError ? null : (lastError ?? this.lastError),
      );

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'consentGranted': consentGranted,
        'paused': paused,
        'wifiOnly': wifiOnly,
        'chargingOnly': chargingOnly,
        'keepFullOfflineIndex': keepFullOfflineIndex,
        'localBudgetMb': localBudgetMb,
        'selectedDocumentIds': selectedDocumentIds.toList()..sort(),
        'phase': phase.name,
        'lastSuccessfulSync': lastSuccessfulSync?.toIso8601String(),
        'lastError': lastError,
      };

  factory CloudIndexSettings.fromJson(Map<String, dynamic> json) {
    CloudSyncPhase phase = CloudSyncPhase.disabled;
    for (final candidate in CloudSyncPhase.values) {
      if (candidate.name == json['phase']) phase = candidate;
    }
    return CloudIndexSettings(
      enabled: json['enabled'] == true,
      consentGranted: json['consentGranted'] == true,
      paused: json['paused'] == true,
      wifiOnly: json['wifiOnly'] != false,
      chargingOnly: json['chargingOnly'] != false,
      keepFullOfflineIndex: json['keepFullOfflineIndex'] != false,
      localBudgetMb:
          ((json['localBudgetMb'] as num?)?.toInt() ?? 250).clamp(50, 2000),
      selectedDocumentIds: (json['selectedDocumentIds'] as List? ?? const [])
          .map((value) => '$value')
          .toSet(),
      phase: phase,
      lastSuccessfulSync:
          DateTime.tryParse('${json['lastSuccessfulSync'] ?? ''}'),
      lastError: json['lastError'] as String?,
    );
  }
}

class CloudDocumentLocator {
  const CloudDocumentLocator({
    required this.documentId,
    required this.localUri,
    required this.title,
    required this.mimeType,
    required this.fileHash,
    required this.fileSize,
    required this.modifiedSeconds,
    this.availableOffline = true,
  });

  final String documentId;
  final String localUri;
  final String title;
  final String mimeType;
  final String fileHash;
  final int fileSize;
  final int modifiedSeconds;
  final bool availableOffline;

  Map<String, Object?> toJson() => {
        'documentId': documentId,
        'localUri': localUri,
        'title': title,
        'mimeType': mimeType,
        'fileHash': fileHash,
        'fileSize': fileSize,
        'modifiedSeconds': modifiedSeconds,
        'availableOffline': availableOffline,
      };

  factory CloudDocumentLocator.fromJson(Map<String, dynamic> json) =>
      CloudDocumentLocator(
        documentId: '${json['documentId'] ?? ''}',
        localUri: '${json['localUri'] ?? ''}',
        title: '${json['title'] ?? ''}',
        mimeType: '${json['mimeType'] ?? ''}',
        fileHash: '${json['fileHash'] ?? ''}',
        fileSize: (json['fileSize'] as num?)?.toInt() ?? 0,
        modifiedSeconds: (json['modifiedSeconds'] as num?)?.toInt() ?? 0,
        availableOffline: json['availableOffline'] != false,
      );
}

class CloudSearchHit {
  const CloudSearchHit({
    required this.documentId,
    required this.title,
    required this.snippet,
    required this.score,
    this.mimeType = 'application/octet-stream',
    this.pageNumber,
    this.revision = '',
  });

  final String documentId;
  final String title;
  final String snippet;
  final double score;
  final String mimeType;
  final int? pageNumber;
  final String revision;

  factory CloudSearchHit.fromJson(Map<String, dynamic> json) => CloudSearchHit(
        documentId: '${json['documentId'] ?? ''}',
        title: '${json['title'] ?? ''}',
        snippet: '${json['snippet'] ?? ''}',
        score: (json['score'] as num?)?.toDouble() ?? 0,
        mimeType: '${json['mimeType'] ?? 'application/octet-stream'}',
        pageNumber: (json['pageNumber'] as num?)?.toInt(),
        revision: '${json['revision'] ?? ''}',
      );

  SearchResult toSearchResult(CloudDocumentLocator? locator) {
    final local = locator != null && locator.localUri.isNotEmpty;
    final offline = local && locator.availableOffline;
    final source = offline
        ? DocumentAvailability.availableOffline
        : local
            ? DocumentAvailability.onDevice
            : DocumentAvailability.cloudIndex;
    return SearchResult(
      kind: ResultKind.document,
      title: title,
      subtitle: [
        source == DocumentAvailability.availableOffline
            ? 'Available offline'
            : source == DocumentAvailability.onDevice
                ? 'On this device'
                : 'Cloud index',
        if (pageNumber != null && pageNumber! > 0) 'Page $pageNumber',
        if (snippet.trim().isNotEmpty) snippet.trim(),
      ].join(' • '),
      icon: Icons.cloud_outlined,
      path: locator?.localUri,
      mimeType: mimeType,
      relevance: score,
      documentId: documentId,
      documentAvailability: source,
      pageNumber: pageNumber,
      localOriginalAvailable: local,
      expectedFileSize: locator?.fileSize,
      expectedModifiedSeconds: locator?.modifiedSeconds,
    );
  }
}

class CloudStorageBreakdown {
  const CloudStorageBreakdown({
    this.localDocumentIndexBytes = 0,
    this.localKnowledgeGraphBytes = 0,
    this.embeddingBytes = 0,
    this.ocrChunkBytes = 0,
    this.previewCacheBytes = 0,
    this.localDocumentCount = 0,
    this.cloudDocumentCount = 0,
  });

  final int localDocumentIndexBytes;
  final int localKnowledgeGraphBytes;
  final int embeddingBytes;
  final int ocrChunkBytes;
  final int previewCacheBytes;
  final int localDocumentCount;
  final int cloudDocumentCount;
}

/// Cloud hits enrich local results but never displace an openable local file.
List<SearchResult> mergeHybridResults(
  List<SearchResult> local,
  List<SearchResult> cloud,
) {
  final merged = <SearchResult>[];
  final byIdentity = <String, int>{};
  List<String> identities(SearchResult result) => [
        if (result.documentId?.isNotEmpty == true) 'id:${result.documentId}',
        if (result.path?.isNotEmpty == true) 'path:${result.path}',
        '${result.kind.name}:${result.title.toLowerCase()}',
      ];

  for (final result in [...local, ...cloud]) {
    final keys = identities(result);
    int? existing;
    for (final key in keys) {
      existing ??= byIdentity[key];
    }
    if (existing == null) {
      for (final key in keys) {
        byIdentity[key] = merged.length;
      }
      merged.add(result);
      continue;
    }
    final previous = merged[existing];
    if (!previous.localOriginalAvailable && result.localOriginalAvailable) {
      merged[existing] = result;
    }
    for (final key in keys) {
      byIdentity[key] = existing;
    }
  }
  return merged;
}

class LocalBudgetPolicy {
  const LocalBudgetPolicy(this.megabytes);
  final int megabytes;
  int get bytes => megabytes.clamp(50, 2000) * 1024 * 1024;
  bool isExceededBy(int bytesUsed) => bytesUsed > bytes;
}
