import 'dart:async';

import 'package:smart_search_app/features/chat/data/chat_store.dart';
import 'package:smart_search_app/features/chat/data/gemini_client.dart';
import 'package:smart_search_app/features/chat/data/gemini_settings_store.dart';
import 'package:smart_search_app/features/chat/domain/chat_document_context.dart';
import 'package:smart_search_app/features/chat/domain/chat_models.dart';

class MemoryChatStore implements ChatStore {
  final Map<String, ChatThread> saved = {};
  int loads = 0;
  bool failWrites = false;
  @override
  Future<List<ChatThread>> load() async {
    loads++;
    return saved.values.toList();
  }

  @override
  Future<void> save(ChatThread thread) async {
    if (failWrites) throw StateError('Disk full');
    saved[thread.id] = thread;
  }

  @override
  Future<void> delete(String id) async {
    saved.remove(id);
  }
}

class MemoryGeminiSettings implements GeminiSettingsStore {
  MemoryGeminiSettings(
      {this.settings = const GeminiSettings(apiKey: 'test-only-key')});
  GeminiSettings settings;
  int reads = 0;
  @override
  Future<GeminiSettings> read() async {
    reads++;
    return settings;
  }

  @override
  Future<void> write(GeminiSettings settings) async {
    this.settings = settings;
  }

  @override
  Future<void> remove() async {
    settings = const GeminiSettings();
  }
}

class FakeGeminiGateway implements GeminiGateway {
  final List<List<ChatMessage>> contexts = [];
  final List<GeminiCancellation> cancellations = [];
  final List<ChatDocumentContext?> documentContexts = [];
  Stream<String> Function()? response;
  int tests = 0;
  @override
  Stream<String> reply(
      {required GeminiSettings settings,
      required List<ChatMessage> messages,
      ChatDocumentContext? documentContext,
      required GeminiCancellation cancellation}) {
    contexts.add(List.of(messages));
    documentContexts.add(documentContext);
    cancellations.add(cancellation);
    return response?.call() ?? Stream.fromIterable(['A clear ', '**answer**.']);
  }

  @override
  Future<void> testConnection(GeminiSettings settings) async {
    tests++;
  }
}
