import 'dart:convert';
import 'dart:math' as math;

import 'package:smart_search_app/features/documents/domain/document_intelligence.dart';

/// Plain data only: this entry point runs outside Flutter's UI isolate.
List<Map<String, dynamic>> rankDocumentBatch(Map<String, dynamic> request) {
  return DocumentRanker().rank(request);
}

class _Candidate {
  _Candidate({
    required this.index,
    required this.raw,
    required this.prepared,
    required this.body,
    required this.lexicalScore,
    required this.relevanceScore,
    required this.semanticSimilarity,
    required this.graphScore,
    required this.graphReasons,
    required this.graphOnlyEligible,
  });

  final int index;
  final Map<String, dynamic> raw;
  final PreparedDocumentSearch prepared;
  final String body;
  final int lexicalScore;
  final int relevanceScore;
  final double semanticSimilarity;
  final double graphScore;
  final List<String> graphReasons;
  final bool graphOnlyEligible;
  int lexicalRank = 0;
  int semanticRank = 0;
  int graphRank = 0;
  double fusionScore = 0;
}

/// Worker-owned cache. No Flutter objects or device services are retained.
class DocumentRanker {
  static const _rrfK = 60.0;
  static const _rerankCandidateCount = 20;
  final _prepared =
      <String, ({String name, String body, PreparedDocumentSearch data})>{};

  int get preparedCount => _prepared.length;

  List<Map<String, dynamic>> rank(Map<String, dynamic> request) {
    final query = request['query'] as String;
    final excluded =
        (request['excludedPaths'] as List<String>? ?? const <String>[]).toSet();
    final queryEmbedding = request['embedding'] as List<int>?;
    final candidates = <_Candidate>[];

    var index = 0;
    for (final raw in request['documents'] as List<Map<String, dynamic>>) {
      if (excluded.contains(raw['path'])) continue;
      final name = raw['name'] as String;
      final content = raw['content'] as String? ?? '';
      final headings =
          (raw['headings'] as List?)?.cast<String>() ?? const <String>[];
      final body = <String>[...headings, content]
          .where((part) => part.trim().isNotEmpty)
          .join('\n');
      final key = '${raw['path'] ?? name}|${raw['type']}';
      var cached = _prepared[key];
      if (cached == null || cached.name != name || cached.body != body) {
        final profile = DocumentIntelligence.infer(
          name: name,
          mimeType: raw['type'] as String,
          content: body,
        );
        cached = (
          name: name,
          body: body,
          data: PreparedDocumentSearch(name, body, profile)
        );
        _prepared[key] = cached;
      }

      final chunkSimilarity = _cosine(
        raw['embedding'] as String? ?? '',
        queryEmbedding,
      );
      final fileSimilarity = _cosine(
        raw['fileEmbedding'] as String? ?? '',
        queryEmbedding,
      );
      final semanticSimilarity = math.max(chunkSimilarity, fileSimilarity);
      final lexicalScore = DocumentIntelligence.score(
        query: query,
        name: name,
        mimeType: raw['type'] as String,
        content: body,
        profile: cached.data.profile,
        prepared: cached.data,
      );
      final relevanceScore = DocumentIntelligence.score(
        query: query,
        name: name,
        mimeType: raw['type'] as String,
        content: body,
        profile: cached.data.profile,
        prepared: cached.data,
        semanticSimilarity: semanticSimilarity,
      );
      final graphScore = (raw['graphScore'] as num?)?.toDouble() ?? 0;
      final graphReasons =
          (raw['graphReasons'] as List?)?.cast<String>() ?? const <String>[];
      final relationalQuery = RegExp(
        r'\b(related|opened with|use together)\b',
        caseSensitive: false,
      ).hasMatch(query);
      final temporalQuery = RegExp(
        r'\b(yesterday|today|last week|past week|last month|past month|recently|last (monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b',
        caseSensitive: false,
      ).hasMatch(query);
      final graphOnlyEligible = graphScore >= 0.45 &&
          ((relationalQuery &&
                  graphReasons.any((reason) =>
                      reason.toLowerCase().contains('opened with'))) ||
              (temporalQuery &&
                  graphReasons
                      .any((reason) => reason.contains('requested time')) &&
                  DocumentIntelligence.hasSubjectEvidence(query, name, body)));
      if (relevanceScore <= 0 && !graphOnlyEligible) continue;
      candidates.add(_Candidate(
        index: index++,
        raw: raw,
        prepared: cached.data,
        body: body,
        lexicalScore: lexicalScore,
        relevanceScore: relevanceScore,
        semanticSimilarity: semanticSimilarity,
        graphScore: graphScore,
        graphReasons: graphReasons,
        graphOnlyEligible: graphOnlyEligible,
      ));
    }

    _assignRanks(candidates);
    for (final candidate in candidates) {
      if (candidate.lexicalRank > 0) {
        candidate.fusionScore += 1 / (_rrfK + candidate.lexicalRank);
      }
      if (candidate.semanticRank > 0) {
        candidate.fusionScore += 1.1 / (_rrfK + candidate.semanticRank);
      }
      if (candidate.graphRank > 0) {
        candidate.fusionScore += 0.8 / (_rrfK + candidate.graphRank);
      }
    }
    candidates.sort((a, b) {
      final fusion = b.fusionScore.compareTo(a.fusionScore);
      if (fusion != 0) return fusion;
      return b.relevanceScore.compareTo(a.relevanceScore);
    });

    // The existing intent-aware scorer is a cheap query+passage reranker. Run
    // it only over the fused top candidates; the MiniLM embeddings and FTS
    // lists decide recall, while contradictions remain hard exclusions.
    final top = candidates.take(_rerankCandidateCount).toList()
      ..sort((a, b) {
        final relevance = b.relevanceScore.compareTo(a.relevanceScore);
        if (relevance != 0) return relevance;
        return b.fusionScore.compareTo(a.fusionScore);
      });
    candidates
      ..removeRange(0, top.length)
      ..insertAll(0, top);

    final ranked =
        candidates.map((candidate) => _toResult(candidate, query)).toList();
    while (_prepared.length > 12000) {
      _prepared.remove(_prepared.keys.first);
    }
    ranked.sort((a, b) {
      final score = (b['score'] as int).compareTo(a['score'] as int);
      if (score != 0) return score;
      final date = (b['modified'] as int).compareTo(a['modified'] as int);
      if (date != 0) return date;
      return (a['name'] as String).compareTo(b['name'] as String);
    });
    return ranked;
  }

  void _assignRanks(List<_Candidate> candidates) {
    final lexical = candidates.where((item) => item.lexicalScore > 0).toList()
      ..sort((a, b) => b.lexicalScore.compareTo(a.lexicalScore));
    var lexicalRank = 0;
    int? previousLexicalScore;
    for (var i = 0; i < lexical.length; i++) {
      final nativeRank = (lexical[i].raw['ftsRank'] as int?) ?? 0;
      if (previousLexicalScore != lexical[i].lexicalScore) {
        lexicalRank = i + 1;
        previousLexicalScore = lexical[i].lexicalScore;
      }
      lexical[i].lexicalRank =
          nativeRank > 0 ? math.min(nativeRank, lexicalRank) : lexicalRank;
    }
    final semantic = candidates
        .where((item) => item.semanticSimilarity > 0.22)
        .toList()
      ..sort((a, b) => b.semanticSimilarity.compareTo(a.semanticSimilarity));
    var semanticRank = 0;
    double? previousSemanticScore;
    for (var i = 0; i < semantic.length; i++) {
      if (previousSemanticScore != semantic[i].semanticSimilarity) {
        semanticRank = i + 1;
        previousSemanticScore = semantic[i].semanticSimilarity;
      }
      semantic[i].semanticRank = semanticRank;
    }
    final graph = candidates.where((item) => item.graphScore > 0).toList()
      ..sort((a, b) => b.graphScore.compareTo(a.graphScore));
    var graphRank = 0;
    double? previousGraphScore;
    for (var i = 0; i < graph.length; i++) {
      final nativeRank = (graph[i].raw['graphRank'] as int?) ?? 0;
      if (previousGraphScore != graph[i].graphScore) {
        graphRank = i + 1;
        previousGraphScore = graph[i].graphScore;
      }
      graph[i].graphRank = nativeRank > 0 ? nativeRank : graphRank;
    }
  }

  Map<String, dynamic> _toResult(_Candidate candidate, String query) {
    final raw = candidate.raw;
    final usageCount = raw['usageCount'] as int? ?? 0;
    final lastOpened = raw['lastOpened'] as int? ?? 0;
    final recentlyOpened = lastOpened > 0 &&
        DateTime.now().millisecondsSinceEpoch - lastOpened <
            const Duration(days: 30).inMilliseconds;
    // Personal behavior is deliberately applied after retrieval/reranking and
    // remains too small to turn an irrelevant document into a match.
    final personalBoost =
        math.min(120, usageCount * 8) + (recentlyOpened ? 60 : 0);
    final pairwiseBoost = math.min(700, candidate.relevanceScore ~/ 6);
    final score = (candidate.fusionScore * 100000).round() +
        pairwiseBoost +
        personalBoost;
    final normalized = candidate.body.replaceAll(RegExp(r'\s+'), ' ').trim();
    var position = normalized.toLowerCase().indexOf(query.toLowerCase());
    if (position < 0) {
      for (final token in DocumentIntelligence.normalize(query).split(' ')) {
        if (token.length < 2) continue;
        final match =
            RegExp('\\b${RegExp.escape(token)}\\b', caseSensitive: false)
                .firstMatch(normalized);
        if (match != null) {
          position = match.start;
          break;
        }
      }
    }
    // Use filename evidence when no exact phrase position is available.
    if (position < 0) {
      final nameTokens = candidate.prepared.nameTokens;
      for (final token in nameTokens) {
        final match =
            RegExp('\\b${RegExp.escape(token)}\\b', caseSensitive: false)
                .firstMatch(normalized);
        if (match != null) {
          position = match.start;
          break;
        }
      }
    }
    final start = position < 0 ? 0 : math.max(0, position - 45);
    final excerpt = normalized.isEmpty
        ? '${raw['summary'] ?? ''}'.trim().isNotEmpty
            ? '${raw['summary']}'.trim()
            : candidate.graphReasons.join(' • ')
        : normalized.substring(start, math.min(normalized.length, start + 160));
    return {
      'name': raw['name'],
      'type': raw['type'],
      'path': raw['path'],
      'modified': raw['modified'],
      'folder': raw['folder'] ?? '',
      'summary': raw['summary'] ?? '',
      'category': raw['category'] ?? 'document',
      'keywords': raw['keywords'] ?? const <String>[],
      'graphScore': candidate.graphScore,
      'graphReasons': candidate.graphReasons,
      'usageCount': usageCount,
      'lastOpened': lastOpened,
      'semanticSimilarity': candidate.semanticSimilarity,
      'fusionScore': candidate.fusionScore,
      'score': score,
      'excerpt': excerpt,
    };
  }

  double _cosine(String encoded, List<int>? query) {
    if (encoded.isEmpty || query == null) return 0;
    try {
      final vector = base64Decode(encoded)
          .map((byte) => byte > 127 ? byte - 256 : byte)
          .toList();
      if (vector.length != query.length) return 0;
      var dot = 0.0, a = 0.0, b = 0.0;
      for (var i = 0; i < vector.length; i++) {
        dot += vector[i] * query[i];
        a += vector[i] * vector[i];
        b += query[i] * query[i];
      }
      return a > 0 && b > 0 ? dot / math.sqrt(a * b) : 0;
    } catch (_) {
      return 0;
    }
  }
}
