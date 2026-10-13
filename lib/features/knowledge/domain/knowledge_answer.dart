class KnowledgeEvidence {
  const KnowledgeEvidence({
    required this.title,
    this.summary = '',
    this.excerpt = '',
    this.category = 'document',
    this.folder = '',
    this.reasons = const <String>[],
  });

  final String title;
  final String summary;
  final String excerpt;
  final String category;
  final String folder;
  final List<String> reasons;
}

class KnowledgeAnswer {
  const KnowledgeAnswer({
    required this.headline,
    required this.body,
    required this.evidenceLabels,
    required this.relationships,
  });

  final String headline;
  final String body;
  final List<String> evidenceLabels;
  final List<String> relationships;

  Map<String, Object> toJson() => {
        'headline': headline,
        'body': body,
        'evidenceLabels': evidenceLabels,
        'relationships': relationships,
      };

  factory KnowledgeAnswer.fromJson(Map<String, dynamic> json) =>
      KnowledgeAnswer(
        headline: '${json['headline'] ?? ''}',
        body: '${json['body'] ?? ''}',
        evidenceLabels: (json['evidenceLabels'] as List? ?? const [])
            .map((item) => '$item')
            .toList(),
        relationships: (json['relationships'] as List? ?? const [])
            .map((item) => '$item')
            .toList(),
      );
}

class KnowledgeConversationTurn {
  const KnowledgeConversationTurn({
    required this.id,
    required this.query,
    required this.createdAt,
    this.answer,
  });

  final String id;
  final String query;
  final DateTime createdAt;
  final KnowledgeAnswer? answer;

  KnowledgeConversationTurn withAnswer(KnowledgeAnswer value) =>
      KnowledgeConversationTurn(
        id: id,
        query: query,
        createdAt: createdAt,
        answer: value,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'query': query,
        'createdAt': createdAt.toIso8601String(),
        'answer': answer?.toJson(),
      };

  factory KnowledgeConversationTurn.fromJson(Map<String, dynamic> json) {
    final answer = json['answer'];
    return KnowledgeConversationTurn(
      id: '${json['id'] ?? ''}',
      query: '${json['query'] ?? ''}',
      createdAt: DateTime.tryParse('${json['createdAt'] ?? ''}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      answer: answer is Map
          ? KnowledgeAnswer.fromJson(Map<String, dynamic>.from(answer))
          : null,
    );
  }
}

/// Produces an honest, local extractive answer from retrieved evidence.
/// It never invents facts that are not represented by the matched files.
class KnowledgeAnswerComposer {
  const KnowledgeAnswerComposer._();

  static KnowledgeAnswer? compose(
    String query,
    List<KnowledgeEvidence> evidence,
  ) {
    final unique = <String, KnowledgeEvidence>{};
    for (final item in evidence) {
      unique.putIfAbsent(item.title.toLowerCase(), () => item);
    }
    final items = unique.values.take(5).toList();
    if (items.isEmpty) return null;

    final relationships = <String>{};
    for (final item in items) {
      relationships.addAll(item.reasons.where((reason) => reason.isNotEmpty));
      if (item.folder.isNotEmpty) relationships.add('Folder: ${item.folder}');
    }

    final descriptions = items.take(3).map((item) {
      final context = item.summary.trim().isNotEmpty
          ? item.summary.trim()
          : item.excerpt.trim();
      return context.isEmpty ? item.title : '${item.title}: $context';
    }).join(' ');

    final normalizedQuery = query.trim();
    return KnowledgeAnswer(
      headline: items.length == 1
          ? 'I found one relevant file'
          : 'I found ${items.length} relevant files',
      body: descriptions.isEmpty
          ? 'These files are the strongest local matches for “$normalizedQuery”.'
          : descriptions,
      evidenceLabels: items.map((item) => item.title).toList(),
      relationships: relationships.take(4).toList(),
    );
  }
}
