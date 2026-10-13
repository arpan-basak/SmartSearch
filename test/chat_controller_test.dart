import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_search_app/core/storage/preference_keys.dart';
import 'package:smart_search_app/features/chat/application/chat_controller.dart';
import 'package:smart_search_app/features/chat/data/chat_store.dart';
import 'package:smart_search_app/features/chat/data/gemini_client.dart';
import 'package:smart_search_app/features/chat/data/gemini_settings_store.dart';
import 'package:smart_search_app/features/chat/domain/chat_models.dart';

import 'chat_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryChatStore store;
  late MemoryGeminiSettings settings;
  late FakeGeminiGateway gateway;
  late ChatController controller;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = MemoryChatStore();
    settings = MemoryGeminiSettings();
    gateway = FakeGeminiGateway();
    controller = ChatController(
        store: store,
        settingsStore: settings,
        gateway: gateway,
        migrateLegacy: false);
  });
  tearDown(() => controller.dispose());

  test('construction does no startup I/O', () {
    expect(store.loads, 0);
    expect(settings.reads, 0);
    expect(gateway.contexts, isEmpty);
  });

  test('separate conversations keep separate context and survive reopening',
      () async {
    final a = await controller.create();
    await controller.send(a.id, 'Explain compression');
    final b = await controller.create();
    await controller.send(b.id, 'Explain databases');
    await controller.send(a.id, 'Give an example');
    expect(gateway.contexts[1].map((m) => m.text), ['Explain databases']);
    expect(gateway.contexts[2].map((m) => m.text),
        ['Explain compression', 'A clear **answer**.', 'Give an example']);
    final reopened = ChatController(
        store: store,
        settingsStore: settings,
        gateway: gateway,
        migrateLegacy: false);
    await reopened.initialize();
    expect(reopened.threads.length, 2);
    expect(reopened.thread(a.id)!.messages.length, 4);
    expect(reopened.thread(b.id)!.messages.length, 2);
    expect(reopened.thread(a.id)!.title, 'Explain compression');
    reopened.dispose();
  });

  test('an in-flight answer stays in its original chat', () async {
    final stream = StreamController<String>();
    gateway.response = () => stream.stream;
    final a = await controller.create();
    final pending = controller.send(a.id, 'First question');
    await Future<void>.delayed(Duration.zero);
    final b = await controller.create();
    stream.add('Answer for first');
    await stream.close();
    await pending;
    expect(controller.thread(b.id)!.messages, isEmpty);
    expect(controller.thread(a.id)!.messages.last.text, 'Answer for first');
  });

  test('deleting an active chat cannot resurrect it with a late response',
      () async {
    final stream = StreamController<String>();
    gateway.response = () => stream.stream;
    final a = await controller.create();
    final pending = controller.send(a.id, 'Hello');
    await Future<void>.delayed(Duration.zero);
    await controller.delete(a.id);
    stream.add('Too late');
    await stream.close();
    await pending;
    expect(controller.thread(a.id), isNull);
    expect(store.saved.containsKey(a.id), isFalse);
    expect(gateway.cancellations.single.cancelled, isTrue);
  });

  test(
      'failed answer is saved; retry replaces placeholder without duplicate user',
      () async {
    gateway.response =
        () => Stream.error(const GeminiException('Quota reached'));
    final a = await controller.create();
    await controller.send(a.id, 'Hi');
    expect(store.saved[a.id]!.messages.last.status, MessageStatus.failed);
    gateway.response = null;
    await controller.send(a.id, '', retry: true);
    expect(controller.thread(a.id)!.messages.length, 2);
    expect(
        controller.thread(a.id)!.messages.last.status, MessageStatus.complete);
    expect(gateway.contexts.last.map((m) => m.text), ['Hi']);
  });

  test('partial failed exchanges are not silently sent as reliable context',
      () async {
    gateway.response = () async* {
      yield 'Partial';
      throw const GeminiException('Disconnected');
    };
    final a = await controller.create();
    await controller.send(a.id, 'First');
    gateway.response = null;
    await controller.send(a.id, 'Second');
    expect(gateway.contexts.last.map((m) => m.text), ['Second']);
    expect(controller.thread(a.id)!.messages[1].text, 'Partial');
  });

  test('safety failure discards unsafe partial text', () async {
    gateway.response = () async* {
      yield 'Partial';
      throw const GeminiException('Blocked', discardPartial: true);
    };
    final a = await controller.create();
    await controller.send(a.id, 'Question');
    expect(controller.thread(a.id)!.messages.last.text, isEmpty);
  });

  test('stop retains partial response and enables retry', () async {
    final stream = StreamController<String>();
    gateway.response = () => stream.stream;
    final a = await controller.create();
    final pending = controller.send(a.id, 'Hello');
    await Future<void>.delayed(Duration.zero);
    stream.add('Partial');
    await Future<void>.delayed(Duration.zero);
    controller.stop(a.id);
    await stream.close();
    await pending;
    expect(controller.thread(a.id)!.messages.last.status,
        MessageStatus.interrupted);
    expect(controller.thread(a.id)!.messages.last.text, 'Partial');
    expect(controller.isBusy(a.id), isFalse);
  });

  test('restart recovers streaming placeholders as interrupted', () async {
    final a = await controller.create();
    store.saved[a.id] = a.copyWith(messages: [
      ChatMessage(
          id: 'pending',
          role: ChatRole.assistant,
          text: 'Saved portion',
          createdAt: DateTime.now(),
          status: MessageStatus.streaming)
    ]);
    final reopened = ChatController(
        store: store,
        settingsStore: settings,
        gateway: gateway,
        migrateLegacy: false);
    await reopened.initialize();
    expect(
        reopened.thread(a.id)!.messages.last.status, MessageStatus.interrupted);
    reopened.dispose();
  });

  test('missing key and failed persistence never send a network request',
      () async {
    final a = await controller.create();
    settings.settings = const GeminiSettings();
    await expectLater(
        controller.send(a.id, 'Hi'), throwsA(isA<GeminiException>()));
    expect(controller.isBusy(a.id), isFalse);
    settings.settings = const GeminiSettings(apiKey: 'test-only-key');
    store.failWrites = true;
    await expectLater(
        controller.send(a.id, 'Hi'), throwsA(isA<GeminiException>()));
    expect(gateway.contexts, isEmpty);
    expect(controller.thread(a.id)!.messages, isEmpty);
  });

  test('duplicate send while streaming is ignored', () async {
    final stream = StreamController<String>();
    gateway.response = () => stream.stream;
    final a = await controller.create();
    final pending = controller.send(a.id, 'Once');
    await controller.send(a.id, 'Twice');
    await Future<void>.delayed(Duration.zero);
    stream.add('OK');
    await stream.close();
    await pending;
    expect(gateway.contexts.length, 1);
  });

  test('legacy conversation is migrated once and not restored after deletion',
      () async {
    final legacy = jsonEncode([
      {
        'id': 'old',
        'query': 'Old question',
        'createdAt': DateTime.now().toIso8601String()
      }
    ]);
    SharedPreferences.setMockInitialValues(
        {PreferenceKeys.localConversation: legacy});
    final first = <ChatThread>[];
    await migrateLegacyChat(store, first);
    expect(first.single.title, 'Previous conversation');
    await store.delete(first.single.id);
    final second = <ChatThread>[];
    await migrateLegacyChat(store, second);
    expect(second, isEmpty);
    expect(
        (await SharedPreferences.getInstance())
            .getString(PreferenceKeys.localConversation),
        legacy);
  });

  test('API key is kept in secure storage, not preferences, and can be removed',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    const secure = SecureGeminiSettingsStore();
    await secure.write(const GeminiSettings(
        apiKey: 'test-only-secret', model: 'gemini-3.8-flash'));
    expect((await secure.read()).apiKey, 'test-only-secret');
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    await secure.remove();
    expect((await secure.read()).configured, isFalse);
  });

  group('file history', () {
    late Directory directory;
    late FileChatStore files;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('apex-chat-test-');
      files = FileChatStore(directory: () async => directory);
    });
    tearDown(() async {
      await directory.delete(recursive: true);
    });
    ChatThread sample(String title) => ChatThread(
        id: 'test-chat',
        title: title,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026));

    test(
        'round trips, serializes concurrent writes, renames and deletes backups',
        () async {
      await Future.wait(
          [files.save(sample('first')), files.save(sample('last'))]);
      expect((await files.load()).single.title, 'last');
      await files.delete('test-chat');
      expect(await files.load(), isEmpty);
      expect(await directory.list().length, 0);
    });
    test('recovers valid backup if interrupted after moving old revision',
        () async {
      await files.save(sample('saved'));
      await File('${directory.path}/test-chat.json')
          .rename('${directory.path}/test-chat.json.bak');
      expect((await files.load()).single.title, 'saved');
      await files.save(sample('next'));
      expect((await files.load()).single.title, 'next');
    });
    test('corruption cannot silently erase history', () async {
      await files.save(sample('saved'));
      await File('${directory.path}/test-chat.json').writeAsString('corrupt');
      await expectLater(files.load(), throwsFormatException);
      expect(await File('${directory.path}/test-chat.json').readAsString(),
          'corrupt');
    });
    test('path traversal IDs are rejected', () async {
      await expectLater(files.delete('../elsewhere'), throwsArgumentError);
    });
  });
}
