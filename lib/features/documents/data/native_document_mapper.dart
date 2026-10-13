import 'dart:convert';

import 'package:smart_search_app/features/documents/domain/indexed_document.dart';

/// Decodes both legacy and current Android index payloads without changing
/// field defaults, embedding precedence, or timestamp units.
IndexedDocument documentFromPlatformMap(Map<dynamic, dynamic> doc) {
  final path = doc['path'] == null ? null : '${doc['path']}';
  final modifiedSeconds = int.tryParse('${doc['modified'] ?? ''}');
  return IndexedDocument(
    name: '${doc['name'] ?? ''}',
    type: '${doc['type'] ?? 'Document'}',
    path: path,
    context: '${doc['content'] ?? ''}',
    extractedBytes: int.tryParse('${doc['bytes'] ?? 0}') ?? 0,
    category: '${doc['category'] ?? 'document'}',
    categoryConfidence:
        double.tryParse('${doc['categoryConfidence'] ?? 0.25}') ?? 0.25,
    summary: '${doc['summary'] ?? ''}',
    keywords: _profileList(doc['keywords']),
    signals: _profileList(doc['signals']),
    embedding: '${doc['chunkEmbedding'] ?? doc['embedding'] ?? ''}',
    fileEmbedding: '${doc['fileEmbedding'] ?? ''}',
    headings: _profileList(doc['headings']),
    folder: '${doc['folder'] ?? ''}',
    graphScore: double.tryParse('${doc['graphScore'] ?? 0}') ?? 0,
    ftsRank: int.tryParse('${doc['ftsRank'] ?? 0}') ?? 0,
    graphRank: int.tryParse('${doc['graphRank'] ?? 0}') ?? 0,
    graphReasons: _profileList(doc['graphReasons'] ?? doc['retrievalReasons']),
    usageCount: int.tryParse('${doc['usageCount'] ?? 0}') ?? 0,
    lastOpened: (int.tryParse('${doc['lastOpened'] ?? 0}') ?? 0) <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            int.parse('${doc['lastOpened']}')),
    metadata: _profileMap(doc['metadata']),
    profileVersion: int.tryParse('${doc['profileVersion'] ?? 0}') ?? 0,
    modifiedAt: modifiedSeconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(modifiedSeconds * 1000),
    contentHash: '${doc['hash'] ?? ''}',
    fileSize: int.tryParse('${doc['size'] ?? 0}') ?? 0,
  );
}

List<String> _profileList(Object? value) {
  if (value == null) return const <String>[];
  if (value is List) {
    return value
        .map((item) => '$item'.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }
  return '$value'
      .split('|')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}

Map<String, String> _profileMap(Object? value) {
  if (value == null || '$value'.trim().isEmpty) return const <String, String>{};
  try {
    final decoded = value is Map ? value : jsonDecode('$value');
    if (decoded is Map) {
      return decoded.map((key, item) => MapEntry('$key', '$item'));
    }
  } catch (_) {}
  return const <String, String>{};
}
