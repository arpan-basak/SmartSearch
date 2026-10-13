import 'package:smart_search_app/features/documents/domain/document_intelligence.dart';

/// Local document metadata; persisted profile versions control re-inference.
class IndexedDocument {
  const IndexedDocument({
    required this.name,
    required this.type,
    this.path,
    this.context = '',
    this.extractedBytes = 0,
    this.category = 'document',
    this.categoryConfidence = 0.25,
    this.summary = '',
    this.keywords = const <String>[],
    this.signals = const <String>[],
    this.embedding = '',
    this.fileEmbedding = '',
    this.headings = const <String>[],
    this.folder = '',
    this.graphScore = 0,
    this.ftsRank = 0,
    this.graphRank = 0,
    this.graphReasons = const <String>[],
    this.usageCount = 0,
    this.lastOpened,
    this.metadata = const <String, String>{},
    this.profileVersion = 0,
    this.modifiedAt,
    this.contentHash = '',
    this.fileSize = 0,
  });

  final String name;
  final String type;
  final String? path;

  /// Extracted text stays in Android's private app storage and is used only
  /// for finding files by their contents, not just their file names.
  final String context;
  final int extractedBytes;
  final String category;
  final double categoryConfidence;
  final String summary;
  final List<String> keywords;
  final List<String> signals;
  final String embedding;
  final String fileEmbedding;
  final List<String> headings;
  final String folder;
  final double graphScore;
  final int ftsRank;
  final int graphRank;
  final List<String> graphReasons;
  final int usageCount;
  final DateTime? lastOpened;
  final Map<String, String> metadata;
  final int profileVersion;

  /// The MediaStore modification time, when Android made it available.
  final DateTime? modifiedAt;
  final String contentHash;
  final int fileSize;

  DocumentContextProfile get profile {
    if (profileVersion == DocumentIntelligence.profileVersion &&
        (category != 'document' || keywords.isNotEmpty || summary.isNotEmpty)) {
      return DocumentContextProfile(
        category: category,
        confidence: categoryConfidence,
        summary: summary,
        keywords: keywords,
        signals: signals,
        metadata: metadata,
      );
    }
    return DocumentIntelligence.infer(
      name: name,
      mimeType: type,
      content: context,
    );
  }
}
