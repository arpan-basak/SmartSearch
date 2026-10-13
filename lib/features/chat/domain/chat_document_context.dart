import 'dart:convert';

enum DocumentContextStatus { found, empty, unavailable }

class ChatDocumentSource {
  const ChatDocumentSource(
      {required this.id,
      required this.title,
      required this.excerpt,
      required this.path,
      this.reason = ''});
  final String id;
  final String title;
  final String excerpt;
  final String path;
  final String reason;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'excerpt': excerpt,
        'path': path,
        'reason': reason,
      };
  factory ChatDocumentSource.fromJson(Map<String, dynamic> json) =>
      ChatDocumentSource(
          id: json['id'] as String,
          title: json['title'] as String,
          excerpt: json['excerpt'] as String,
          path: json['path'] as String,
          reason: json['reason'] as String? ?? '');
}

class ChatDocumentContext {
  const ChatDocumentContext(this.status, [this.sources = const []]);
  final DocumentContextStatus status;
  final List<ChatDocumentSource> sources;

  String get description => switch (status) {
        DocumentContextStatus.found =>
          '${sources.length} indexed sources provided',
        DocumentContextStatus.empty => 'No matching indexed context found',
        DocumentContextStatus.unavailable =>
          'Indexed context unavailable; using chat only',
      };

  // Paths are kept locally for opening evidence, never sent to the provider.
  String get referenceText => jsonEncode({
        'retrievalStatus': status.name,
        'sources': sources
            .map((s) => {
                  'id': s.id,
                  'title': s.title,
                  'excerpt': s.excerpt,
                  'matchReason': s.reason,
                })
            .toList(),
      });
  Map<String, Object?> toJson() => {
        'status': status.name,
        'sources': sources.map((s) => s.toJson()).toList(),
      };
  factory ChatDocumentContext.fromJson(Map<String, dynamic> json) =>
      ChatDocumentContext(
          DocumentContextStatus.values.byName(json['status'] as String),
          (json['sources'] as List? ?? [])
              .map((s) => ChatDocumentSource.fromJson(
                  Map<String, dynamic>.from(s as Map)))
              .toList());
}
