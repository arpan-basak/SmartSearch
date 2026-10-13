import 'package:flutter/material.dart';
import 'package:smart_search_app/features/search/models/search_result.dart';

/// The existing Android history wire format. Destination and enum spellings
/// are persisted on users' devices; changing them requires a migration.
abstract final class HistoryEntryCodec {
  static SearchResult decode(Map<String, dynamic> map) =>
      _decode(map, parseEmptyUrl: false);

  /// The cached initial snapshot historically retains empty destination URIs;
  /// preserve that distinction from a later `getHistory` response.
  static SearchResult decodeInitialSnapshot(Map<String, dynamic> map) =>
      _decode(map, parseEmptyUrl: true);

  static SearchResult _decode(
    Map<String, dynamic> map, {
    required bool parseEmptyUrl,
  }) {
    final kindStr = map['kind'] as String?;
    final kind = ResultKind.values.firstWhere(
      (e) => e.name == kindStr,
      orElse: () => ResultKind.web,
    );

    final extra = map['extra'] as String?;
    final iconBase64 = map['icon'] as String?;
    Uri? url;
    String? packageName;
    String? path;

    if (kind == ResultKind.app) {
      packageName = extra;
    } else if (kind == ResultKind.document) {
      path = extra;
    } else if (extra != null && (parseEmptyUrl || extra.isNotEmpty)) {
      url = Uri.tryParse(extra);
    }

    return SearchResult(
      kind: kind,
      title: map['title'] ?? '',
      subtitle: map['subtitle'] ?? '',
      icon: _getIconForKind(kind),
      packageName: packageName,
      path: path,
      url: url,
      iconBase64: iconBase64,
      usageCount: map['usageCount'] ?? 0,
      timestamp:
          map['timestamp'] != null ? DateTime.tryParse(map['timestamp']) : null,
    );
  }

  static Map<String, Object?> encode(
    SearchResult result, {
    required String query,
    required DateTime timestamp,
  }) {
    String? extra;
    if (result.kind == ResultKind.app) {
      extra = result.packageName;
    } else if (result.kind == ResultKind.document) {
      extra = result.path;
    } else {
      extra = result.url?.toString();
    }
    return {
      'query': query,
      'kind': result.kind.name,
      'title': result.title,
      'subtitle': result.subtitle,
      'extra': extra,
      'icon': result.kind == ResultKind.app
          ? (result.previewBase64 ?? result.iconBase64)
          : result.iconBase64,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  static IconData _getIconForKind(ResultKind kind) {
    switch (kind) {
      case ResultKind.action:
        return Icons.bolt_rounded;
      case ResultKind.app:
        return Icons.apps_rounded;
      case ResultKind.document:
        return Icons.description_rounded;
      case ResultKind.web:
        return Icons.public_rounded;
    }
  }
}
