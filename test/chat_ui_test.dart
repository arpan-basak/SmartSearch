import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_search_app/app/app.dart';
import 'package:smart_search_app/design_system/nexa_theme.dart';
import 'package:smart_search_app/features/chat/application/chat_controller.dart';
import 'package:smart_search_app/features/chat/data/gemini_settings_store.dart';
import 'package:smart_search_app/features/chat/domain/chat_document_context.dart';
import 'package:smart_search_app/features/chat/domain/chat_models.dart';
import 'package:smart_search_app/features/chat/presentation/chat_screen.dart';
import 'package:smart_search_app/features/chat/presentation/gemini_settings_screen.dart';

import 'chat_test_support.dart';

class ChatTestBinding extends AutomatedTestWidgetsFlutterBinding {
  Future<void>? firstFrame;
  @override
  Future<void> get waitUntilFirstFrameRasterized =>
      firstFrame ?? Future.value();
}

void main() {
  final binding = ChatTestBinding();
  late MemoryChatStore store;
  late MemoryGeminiSettings settings;
  late FakeGeminiGateway gateway;
  late ChatController controller;
  setUp(() {
    binding.firstFrame = null;
    SharedPreferences.setMockInitialValues({'account_welcome_seen': true});
    store = MemoryChatStore();
    settings = MemoryGeminiSettings();
    gateway = FakeGeminiGateway();
    controller = ChatController(
        store: store,
        settingsStore: settings,
        gateway: gateway,
        migrateLegacy: false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('smart_search/apps'),
            (call) async {
      if (call.method == 'getInitialData') {
        return {'history': '[]', 'apps': [], 'contacts': []};
      }
      return null;
    });
  });
  tearDown(() => controller.dispose());

  testWidgets(
      'saved indexed sources are inspectable and context can be disabled',
      (tester) async {
    final thread = await controller.create();
    store.saved[thread.id] = thread.copyWith(messages: [
      ChatMessage(
        id: 'answer',
        role: ChatRole.assistant,
        text: 'Your notes explain light [S1].',
        createdAt: DateTime(2026),
        documentContext:
            const ChatDocumentContext(DocumentContextStatus.found, [
          ChatDocumentSource(
              id: 'S1',
              title: 'Physics notes',
              excerpt: 'Light travels at c.',
              path: 'content://notes/1'),
        ]),
      )
    ]);
    final reopened = ChatController(
        store: store,
        settingsStore: settings,
        gateway: gateway,
        migrateLegacy: false);
    addTearDown(reopened.dispose);
    await reopened.initialize();
    await tester.pumpWidget(MaterialApp(
        home: ChatScreen(
            controller: reopened, threadId: thread.id, onSettings: () {})));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 indexed sources provided'));
    await tester.pumpAndSettle();
    expect(find.text('[S1] Physics notes'), findsOneWidget);
    expect(find.text('Light travels at c.'), findsOneWidget);
    expect(find.text('Open source'), findsOneWidget);
    await tester.tap(find.text('Use indexed documents'));
    await tester.pumpAndSettle();
    expect(store.saved[thread.id]!.useIndexedContext, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new chat is separate and old chat reopens with its own history',
      (tester) async {
    await tester.pumpWidget(SmartSearchApp(chatController: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chats'));
    await tester.pumpAndSettle();
    expect(find.text('Your ideas start here'), findsOneWidget);
    await tester.tap(find.text('New chat'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('chat-composer')), 'Compression question');
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(find.text('Compression question'), findsNWidgets(2));
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('New chat'));
    await tester.pumpAndSettle();
    expect(find.text('Compression question'), findsNothing);
    await tester.enterText(
        find.byKey(const Key('chat-composer')), 'Database question');
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compression question'));
    await tester.pumpAndSettle();
    expect(find.text('Database question'), findsNothing);
    expect(find.text('Compression question'), findsNWidgets(2));
    expect(gateway.contexts[1].single.text, 'Database question');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'chat storage waits for first rasterized frame even if Chats is tapped',
      (tester) async {
    final rasterized = Completer<void>();
    binding.firstFrame = rasterized.future;
    await tester.pumpWidget(SmartSearchApp(chatController: controller));
    await tester.pump();
    expect(store.loads, 0);
    expect(settings.reads, 0);
    await tester.tap(find.text('Chats'));
    await tester.pump();
    expect(store.loads, 0);
    expect(settings.reads, 0);
    rasterized.complete();
    await tester.pumpAndSettle();
    expect(store.loads, 1);
    expect(settings.reads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Settings exposes secure Gemini key entry and model selection',
      (tester) async {
    settings.settings = const GeminiSettings();
    await tester.pumpWidget(SmartSearchApp(chatController: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gemini API'));
    await tester.pumpAndSettle();
    expect(find.text('Gemini settings'), findsOneWidget);
    final keyField = find.widgetWithText(TextField, 'Gemini API key');
    expect(tester.widget<TextField>(keyField).obscureText, isTrue);
    expect(find.text('Chat model'), findsOneWidget);
    await tester.enterText(keyField, 'test-only-key');
    await tester.scrollUntilVisible(find.text('Save key and model'), 200,
        scrollable: find
            .descendant(
                of: find.byType(ListView), matching: find.byType(Scrollable))
            .first);
    await tester.tap(find.text('Save key and model'));
    await tester.pumpAndSettle();
    expect(settings.settings.apiKey, 'test-only-key');
    expect(gateway.contexts, isEmpty);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(controller.hasApiKey, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'saved key is masked; test does not generate; removal keeps chats',
      (tester) async {
    await controller.create();
    await tester.pumpWidget(MaterialApp(
        home: GeminiSettingsScreen(store: settings, gateway: gateway)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Test connection'), 200,
        scrollable: find
            .descendant(
                of: find.byType(ListView), matching: find.byType(Scrollable))
            .first);
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    expect(gateway.tests, 1);
    expect(gateway.contexts, isEmpty);
    await tester.scrollUntilVisible(find.text('Remove saved key'), 150,
        scrollable: find
            .descendant(
                of: find.byType(ListView), matching: find.byType(Scrollable))
            .first);
    await tester.tap(find.text('Remove saved key'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(settings.settings.configured, isFalse);
    expect(store.saved.length, 1);
  });

  testWidgets('narrow phone and keyboard preserve readable chat and composer',
      (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final thread = await controller.create();
    await controller.send(thread.id, 'A question');
    await tester.pumpWidget(MaterialApp(
        theme: NexaTheme.light(),
        home: ChatScreen(
            controller: controller, threadId: thread.id, onSettings: () {})));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.tap(find.byKey(const Key('chat-composer')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Send message').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing API key keeps history readable and send disabled',
      (tester) async {
    final thread = await controller.create();
    await controller.send(thread.id, 'Saved question');
    settings.settings = const GeminiSettings();
    await controller.refreshConfiguration();
    await tester.pumpWidget(MaterialApp(
        home: ChatScreen(
            controller: controller, threadId: thread.id, onSettings: () {})));
    await tester.pumpAndSettle();
    expect(find.text('Saved question'), findsNWidgets(2));
    expect(
        tester
            .widget<IconButton>(find.ancestor(
                of: find.byTooltip('Send message'),
                matching: find.byType(IconButton)))
            .onPressed,
        isNull);
    expect(find.text('Add your Gemini API key'), findsOneWidget);
  });
}
