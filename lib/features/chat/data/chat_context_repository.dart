import 'package:flutter/services.dart';
import 'package:smart_search_app/core/platform/search_platform.dart';
import 'package:smart_search_app/features/chat/domain/chat_document_context.dart';

abstract interface class ChatContextRepository {
  Future<ChatDocumentContext> search(
      String question, List<String> previousQuestions);
}

/// Reads the existing index only when a chat message is sent. No startup work,
/// directory scans, index exports, or new dependencies.
class NativeChatContextRepository implements ChatContextRepository {
  const NativeChatContextRepository({this.platform = searchPlatformChannel});
  final MethodChannel platform;

  static String retrievalQuery(
      String question, List<String> previousQuestions) {
    var query = question.trim();
    final followUp = RegExp(
            r'\b(it|its|that|those|this|these|they|them|their|above|same|more|continue|summarize|summarise)\b|^what about\b',
            caseSensitive: false)
        .hasMatch(query);
    if (followUp && previousQuestions.isNotEmpty) {
      // Retain the topic for "explain that" without mixing unrelated chats.
      final prior = previousQuestions.reversed.take(2).toList().reversed;
      query = '${prior.map((q) => _limit(q, 400)).join(' ')} $query';
    }
    return _limit(query, 1600);
  }

  @override
  Future<ChatDocumentContext> search(
      String question, List<String> previousQuestions) async {
    try {
      final rows =
          await platform.invokeMethod<List<dynamic>>('getChatContext', {
        'query': retrievalQuery(question, previousQuestions),
      }).timeout(const Duration(seconds: 12));
      if (rows == null) {
        return const ChatDocumentContext(DocumentContextStatus.unavailable);
      }
      final sources = <ChatDocumentSource>[];
      final seen = <String>{};
      var remaining = 12000;
      for (final row in rows.whereType<Map>()) {
        final path = '${row['path'] ?? ''}';
        final excerpt =
            _limit('${row['content'] ?? ''}'.trim(), remaining.clamp(0, 2400));
        if (path.isEmpty || excerpt.isEmpty || !seen.add(path)) continue;
        sources.add(ChatDocumentSource(
            id: 'S${sources.length + 1}',
            title: _limit('${row['name'] ?? 'Indexed document'}', 160),
            excerpt: excerpt,
            path: path,
            reason: _limit('${row['retrievalReasons'] ?? ''}', 240)));
        remaining -= excerpt.length;
        if (sources.length == 5 || remaining <= 0) break;
      }
      return ChatDocumentContext(
          sources.isEmpty
              ? DocumentContextStatus.empty
              : DocumentContextStatus.found,
          List.unmodifiable(sources));
    } catch (_) {
      return const ChatDocumentContext(DocumentContextStatus.unavailable);
    }
  }

  static String _limit(String text, int max) {
    if (text.length <= max) return text;
    var end = max;
    if (end > 0 &&
        text.codeUnitAt(end - 1) >= 0xD800 &&
        text.codeUnitAt(end - 1) <= 0xDBFF) {
      end--;
    }
    return text.substring(0, end);
  }
}
