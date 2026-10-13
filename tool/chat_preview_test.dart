// Optional, deterministic UI previews with synthetic data, never a real API key.
// Run with APEX_PREVIEW_FONT pointing at Flutter's roboto-regular.ttf:
// flutter test tool/chat_preview_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_search_app/design_system/nexa_theme.dart';
import 'package:smart_search_app/features/chat/application/chat_controller.dart';
import 'package:smart_search_app/features/chat/domain/chat_models.dart';
import 'package:smart_search_app/features/chat/presentation/chat_list_screen.dart';
import 'package:smart_search_app/features/chat/presentation/chat_screen.dart';
import 'package:smart_search_app/features/chat/presentation/gemini_settings_screen.dart';

import '../test/chat_test_support.dart';

class PreviewBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  Future<void> get waitUntilFirstFrameRasterized => Future.value();
}

void main() {
  PreviewBinding();
  testWidgets('render chat previews', (tester) async {
    final fontPath = Platform.environment['APEX_PREVIEW_FONT'];
    if (fontPath == null) return;
    await tester.runAsync(() async {
      final font = FontLoader('Roboto')
        ..addFont(
            File(fontPath).readAsBytes().then((b) => ByteData.sublistView(b)));
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
            File('${File(fontPath).parent.path}/materialicons-regular.otf')
                .readAsBytes()
                .then((b) => ByteData.sublistView(b)));
      await icons.load();
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryChatStore();
    final settings = MemoryGeminiSettings();
    final gateway = FakeGeminiGateway();
    final controller = ChatController(
        store: store,
        settingsStore: settings,
        gateway: gateway,
        migrateLegacy: false);
    final when = DateTime(2026, 9, 23, 16, 30);
    for (final (id, title, question, answer) in [
      (
        'compression',
        'Understanding data compression',
        'What is the difference between lossless and lossy compression?',
        '**Lossless** compression preserves every bit of the original data. You can reconstruct it exactly.\n\n- **Examples:** ZIP, PNG, FLAC\n- **Best for:** documents, code, and precise data\n\n**Lossy** compression removes some information to make files smaller.\n\n- **Examples:** JPEG, MP3\n- **Best for:** photos, music, and video\n\nFor your class notes, use lossless compression so no text or diagrams are lost.'
      ),
      (
        'study',
        'A study plan for this week',
        'Help me plan my revision.',
        'Let’s divide your subjects into focused, manageable sessions.'
      ),
      (
        'ideas',
        'Ideas for my next project',
        'Suggest a small app project.',
        'Here are a few ideas you can build and test with friends.'
      ),
    ]) {
      store.saved[id] = ChatThread(
          id: id,
          title: title,
          createdAt: when,
          updatedAt: when,
          messages: [
            ChatMessage(
                id: '$id-user',
                role: ChatRole.user,
                text: question,
                createdAt: when),
            ChatMessage(
                id: '$id-model',
                role: ChatRole.assistant,
                text: answer,
                createdAt: when,
                model: 'gemini-3.5-flash-lite'),
          ]);
    }
    await controller.initialize();
    Future<void> render(String name, Widget child, {bool dark = true}) async {
      final base = dark ? NexaTheme.dark() : NexaTheme.light();
      const label = WidgetStatePropertyAll(
          TextStyle(fontFamily: 'Roboto', fontWeight: FontWeight.w700));
      await tester.pumpWidget(MaterialApp(
          theme: base.copyWith(
            textTheme: base.textTheme.apply(fontFamily: 'Roboto'),
            primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'Roboto'),
            appBarTheme: base.appBarTheme.copyWith(
                titleTextStyle: base.appBarTheme.titleTextStyle
                    ?.copyWith(fontFamily: 'Roboto')),
            filledButtonTheme: FilledButtonThemeData(
                style:
                    base.filledButtonTheme.style?.copyWith(textStyle: label)),
            outlinedButtonTheme: OutlinedButtonThemeData(
                style:
                    base.outlinedButtonTheme.style?.copyWith(textStyle: label)),
            textButtonTheme: TextButtonThemeData(
                style: base.textButtonTheme.style?.copyWith(textStyle: label)),
          ),
          home: RepaintBoundary(key: const Key('preview'), child: child)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(find.byKey(const Key('preview')),
          matchesGoldenFile('../build/chat-previews/$name.png'));
    }

    await render(
        'chats-dark',
        Scaffold(
            body: ChatListScreen(
                controller: controller,
                onOpen: (_) {},
                onNew: () {},
                onSettings: () {}),
            bottomNavigationBar:
                NavigationBar(selectedIndex: 1, destinations: const [
              NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
              NavigationDestination(
                  icon: Icon(Icons.chat_bubble), label: 'Chats')
            ])));
    await render(
        'conversation-dark',
        ChatScreen(
            controller: controller,
            threadId: 'compression',
            onSettings: () {}));
    await render(
        'conversation-light',
        ChatScreen(
            controller: controller, threadId: 'compression', onSettings: () {}),
        dark: false);
    await render('gemini-settings',
        GeminiSettingsScreen(store: settings, gateway: gateway));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
