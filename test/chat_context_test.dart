import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_search_app/features/chat/application/chat_controller.dart';
import 'package:smart_search_app/features/chat/data/chat_context_repository.dart';
import 'package:smart_search_app/features/chat/domain/chat_document_context.dart';
import 'package:smart_search_app/features/chat/domain/chat_models.dart';

import 'chat_test_support.dart';

class FakeContextRepository implements ChatContextRepository {
  final queries = <String>[];
  final histories = <List<String>>[];
  Future<ChatDocumentContext> Function()? response;
  @override
  Future<ChatDocumentContext> search(
      String question, List<String> previousQuestions) {
    queries.add(question);
    histories.add(previousQuestions);
    return response?.call() ?? Future.value(evidence);
  }
}

const evidence = ChatDocumentContext(DocumentContextStatus.found, [
  ChatDocumentSource(
      id: 'S1',
      title: 'Physics notes',
      excerpt: 'Light travels at c.',
      path: 'content://private/notes',
      reason: 'Full-text match'),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const platform = MethodChannel('chat-context-test');
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(platform, null));

  test(
      'native retrieval is bounded, deduplicated, and does not export the index',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platform, (call) async {
      calls.add(call);
      final row = {
        'path': 'content://notes/0',
        'name': 'Notes',
        'content': '📝' * 3000
      };
      return [
        row,
        row,
        for (var i = 1; i < 10; i++) {...row, 'path': 'content://notes/$i'}
      ];
    });
    final repo = NativeChatContextRepository(platform: platform);
    expect(calls, isEmpty);
    final result = await repo.search('Explain that', ['Physics notes']);
    expect(calls.single.method, 'getChatContext');
    expect((calls.single.arguments as Map)['query'], contains('Physics notes'));
    expect(result.sources.length, 5);
    expect(result.sources.map((s) => s.path).toSet().length, 5);
    expect(result.sources.fold<int>(0, (n, s) => n + s.excerpt.length),
        lessThanOrEqualTo(12000));
    expect(result.referenceText, isNot(contains('content://')));
  });

  test('no matches and unavailable index remain distinguishable', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platform, (_) async => []);
    const repo = NativeChatContextRepository(platform: platform);
    expect(
        (await repo.search('Physics', [])).status, DocumentContextStatus.empty);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platform,
            (_) async => throw PlatformException(code: 'UNAVAILABLE'));
    expect((await repo.search('Physics', [])).status,
        DocumentContextStatus.unavailable);
    expect(
        NativeChatContextRepository.retrievalQuery(
            'Plan a holiday', ['Physics notes']),
        'Plan a holiday');
  });

  late MemoryChatStore store;
  late FakeGeminiGateway gateway;
  late FakeContextRepository repository;
  late ChatController controller;
  setUp(() {
    store = MemoryChatStore();
    gateway = FakeGeminiGateway();
    repository = FakeContextRepository();
    controller = ChatController(
        store: store,
        settingsStore: MemoryGeminiSettings(),
        gateway: gateway,
        contextRepository: repository,
        migrateLegacy: false);
  });
  tearDown(() => controller.dispose());

  test('context is fetched only on send and source snapshots survive reopening',
      () async {
    final first = await controller.create();
    expect(repository.queries, isEmpty);
    await controller.send(first.id, 'Explain my physics notes');
    expect(gateway.documentContexts.single, evidence);
    final saved = ChatThread.fromJson(
        jsonDecode(jsonEncode(store.saved[first.id]!.toJson()))
            as Map<String, dynamic>);
    expect(saved.messages.last.documentContext!.sources.single.excerpt,
        'Light travels at c.');
    expect(saved.messages.first.text, 'Explain my physics notes');
    final other = await controller.create();
    await controller.send(other.id, 'Biology notes');
    expect(repository.histories.last, isEmpty);
    await controller.send(first.id, 'Explain that in detail');
    expect(repository.histories.last, ['Explain my physics notes']);
  });

  test('disabling context persists and never fetches or sends new excerpts',
      () async {
    final thread = await controller.create();
    await controller.setIndexedContext(thread.id, false);
    await controller.send(thread.id, 'Explain my notes');
    expect(repository.queries, isEmpty);
    expect(gateway.documentContexts.single, isNull);
    expect(
        ChatThread.fromJson(store.saved[thread.id]!.toJson()).useIndexedContext,
        isFalse);
  });

  test('stop during lookup prevents any Gemini request', () async {
    final lookup = Completer<ChatDocumentContext>();
    repository.response = () => lookup.future;
    final thread = await controller.create();
    final pending = controller.send(thread.id, 'Explain my notes');
    await Future<void>.delayed(Duration.zero);
    expect(controller.isRetrieving(thread.id), isTrue);
    controller.stop(thread.id);
    await pending;
    expect(gateway.contexts, isEmpty);
    expect(controller.thread(thread.id)!.messages.last.status,
        MessageStatus.interrupted);
    lookup.complete(evidence);
    await Future<void>.delayed(Duration.zero);
    expect(gateway.contexts, isEmpty);
  });

  test('failed retrieval is explicit and retry fetches fresh context',
      () async {
    repository.response = () => Future.error(StateError('Index unavailable'));
    final thread = await controller.create();
    await controller.send(thread.id, 'Explain my notes');
    expect(gateway.documentContexts.single!.status,
        DocumentContextStatus.unavailable);
    gateway.response = () => Stream.error(StateError('Disconnected'));
    await controller.send(thread.id, 'Try another question');
    repository.response = null;
    gateway.response = null;
    await controller.send(thread.id, '', retry: true);
    expect(repository.queries.last, 'Try another question');
    expect(gateway.documentContexts.last, evidence);
  });
}
