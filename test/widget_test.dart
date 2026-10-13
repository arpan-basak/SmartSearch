import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_search_app/app/app.dart';
import 'package:smart_search_app/design_system/nexa_theme.dart';
import 'package:smart_search_app/features/history/presentation/history_screen.dart';
import 'package:smart_search_app/features/search/models/search_result.dart';
import 'package:smart_search_app/features/search/presentation/search_screen.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text_platform_interface/method_channel_speech_to_text.dart';
import 'package:speech_to_text_platform_interface/speech_to_text_platform_interface.dart';

class StartupTestBinding extends AutomatedTestWidgetsFlutterBinding {
  Future<void>? firstFrameReady;

  // Widget tests do not run the engine's raster thread. Expose its completion
  // explicitly so the startup ordering can be tested instead of bypassed.
  @override
  Future<void> get waitUntilFirstFrameRasterized =>
      firstFrameReady ?? Future<void>.value();
}

void main() {
  final binding = StartupTestBinding();

  const channel = MethodChannel('smart_search/apps');
  const speechChannel = MethodChannel('plugin.csdcorp.com/speech_to_text');
  final speechPlatform = MethodChannelSpeechToText();
  String historyJson = '[]';
  int directCalls = 0;
  int speechListenCalls = 0;
  List<String> speechMethods = [];
  List<MethodCall> artworkCalls = [];
  List<MethodCall> platformCalls = [];
  String documentIndexMode = 'balanced';
  Map<String, int> documentIndexSchedule = {
    'startMinute': 0,
    'endMinute': 420,
  };
  String? lastDirectCall;
  List<Map<String, String>> contacts = [];
  Map<String, Completer<List<dynamic>>>? nativeSearches;
  List<String> pendingImportNames = [];
  List<Map<String, String>> nativeDocuments = [];

  Future<void> sendSpeechCallback(String method, Object arguments) async {
    final platform = SpeechToTextPlatform.instance;
    expect(platform, isA<MethodChannelSpeechToText>());
    await (platform as MethodChannelSpeechToText)
        .processMethodCall(MethodCall(method, arguments));
  }

  Future<void> sendFinalSpeech(
    String words, {
    double confidence = 0.9,
  }) =>
      sendSpeechCallback(
        'textRecognition',
        jsonEncode({
          'alternates': [
            {
              'recognizedWords': words,
              'recognizedPhrases': null,
              'confidence': confidence,
            }
          ],
          'resultType': 2,
        }),
      );

  Future<void> pressVoiceButton(WidgetTester tester) async {
    final button = tester.widget<IconButton>(find.ancestor(
      of: find.byTooltip('Start voice input'),
      matching: find.byType(IconButton),
    ));
    await tester.runAsync(() async {
      final result = (button.onPressed as dynamic)();
      if (result is Future) {
        await result.timeout(const Duration(seconds: 5));
      }
    });
    await tester.pump();
  }

  Future<void> waitForDocumentResults(WidgetTester tester) async {
    for (var attempt = 0; attempt < 40; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      if (find.text('Project plan.pdf').evaluate().isNotEmpty) return;
    }
  }

  Future<void> openFileIndexingSettings(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    final filesAndOcr = find.text('Files and OCR');
    await tester.scrollUntilVisible(
      filesAndOcr,
      220,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(filesAndOcr);
    await tester.pumpAndSettle();
    expect(find.text('File indexing'), findsOneWidget);
  }

  Future<void> flushVoiceTasks(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    for (var step = 0; step < 10; step++) {
      await tester.pump();
    }
  }

  Future<void> stopVoiceSession(WidgetTester tester) async {
    final stopButton = find.byTooltip('Stop voice search');
    if (stopButton.evaluate().isNotEmpty) {
      final button = tester.widget<IconButton>(find.ancestor(
        of: stopButton,
        matching: find.byType(IconButton),
      ));
      await tester.runAsync(() async {
        final result = (button.onPressed as dynamic)();
        if (result is Future) await result;
      });
      await flushVoiceTasks(tester);
      await tester.pump(const Duration(seconds: 3));
    }
    // Force disposal so speech_to_text cancels its own listen/pause timer.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await SpeechToText().cancel();
    await tester.pump(const Duration(seconds: 3));
    await SpeechToText().cancel();
    await tester.pump(const Duration(seconds: 3));
  }

  setUp(() {
    // SpeechToText is a process singleton, so its platform callbacks must stay
    // attached to one platform instance across all widget tests.
    SpeechToTextPlatform.instance = speechPlatform;
    binding.firstFrameReady = null;
    SharedPreferences.setMockInitialValues({});
    historyJson = '[]';
    directCalls = 0;
    speechListenCalls = 0;
    speechMethods = [];
    artworkCalls = [];
    platformCalls = [];
    documentIndexMode = 'balanced';
    documentIndexSchedule = {
      'startMinute': 0,
      'endMinute': 420,
    };
    lastDirectCall = null;
    nativeSearches = null;
    pendingImportNames = [];
    nativeDocuments = [
      {
        'name': 'Project plan.pdf',
        'type': 'application/pdf',
        'path': 'content://documents/project-plan'
      },
    ];
    contacts = [
      {'name': 'Arpan', 'phone': '8788029538'},
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      platformCalls.add(call);
      switch (call.method) {
        case 'getInitialData':
          return {'history': historyJson, 'apps': [], 'contacts': []};
        case 'getDocumentIndexMode':
          return documentIndexMode;
        case 'setDocumentIndexMode':
          documentIndexMode =
              '${(call.arguments as Map<dynamic, dynamic>)['mode']}';
          return true;
        case 'getDocumentIndexSchedule':
          return documentIndexSchedule;
        case 'setDocumentIndexSchedule':
          final arguments = call.arguments as Map<dynamic, dynamic>;
          documentIndexSchedule = {
            'startMinute': arguments['startMinute'] as int,
            'endMinute': arguments['endMinute'] as int,
          };
          return true;
        case 'restartDocumentIndexing':
          return true;
        case 'getPendingSharedDocuments':
          return {'names': pendingImportNames, 'subject': ''};
        case 'pickNotesToImport':
          pendingImportNames = ['unit1.pdf'];
          return true;
        case 'importSharedDocuments':
          pendingImportNames = [];
          return {'imported': 1, 'failed': 0, 'error': ''};
        case 'removeImportedDocument':
          final path = (call.arguments as Map)['path'];
          nativeDocuments.removeWhere((document) => document['path'] == path);
          return true;
        case 'searchDocuments':
          if (nativeSearches == null) return <dynamic>[];
          final query = '${(call.arguments as Map)['query']}';
          return nativeSearches!
              .putIfAbsent(query, () => Completer<List<dynamic>>())
              .future;
        case 'requestContactsPermission':
          return true;
        case 'getContacts':
          return contacts;
        case 'getApps':
          return [
            {'name': 'WhatsApp', 'package': 'com.whatsapp'},
            {'name': 'Phone', 'package': 'com.android.dialer'},
          ];
        case 'getAppIcon':
        case 'getDocumentPreview':
          artworkCalls.add(call);
          return 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
        case 'getDocuments':
          return nativeDocuments;
        case 'getDocumentIndexStatus':
          return {
            'indexed': 12,
            'total': 40,
            'complete': false,
            'state': 'paused_for_search'
          };
        case 'makeDirectCall':
          directCalls++;
          lastDirectCall = '${(call.arguments as Map)['phone']}';
          return true;
        case 'addToHistory':
          final arguments = Map<String, dynamic>.from(call.arguments as Map);
          final items =
              List<Map<String, dynamic>>.from(jsonDecode(historyJson) as List);
          final existingIndex = items.indexWhere((item) =>
              item['title'] == arguments['title'] &&
              item['kind'] == arguments['kind']);
          if (existingIndex >= 0) {
            final existing = items.removeAt(existingIndex);
            existing
              ..['query'] = arguments['query']
              ..['subtitle'] = arguments['subtitle']
              ..['extra'] = arguments['extra']
              ..['icon'] = arguments['icon'] ?? existing['icon']
              ..['usageCount'] = (existing['usageCount'] as int? ?? 0) + 1
              ..['timestamp'] = arguments['timestamp'];
            items.insert(0, existing);
          } else {
            items.insert(0, {
              'kind': arguments['kind'],
              'title': arguments['title'],
              'subtitle': arguments['subtitle'],
              'extra': arguments['extra'],
              'icon': arguments['icon'],
              'usageCount': 1,
              'timestamp': arguments['timestamp'],
            });
          }
          historyJson = jsonEncode(items);
          return true;
        case 'getHistory':
          return historyJson;
        case 'removeFromHistory':
          final arguments = Map<String, dynamic>.from(call.arguments as Map);
          final items = (jsonDecode(historyJson) as List)
              .where((item) =>
                  item['title'] != arguments['title'] ||
                  item['kind'] != arguments['kind'])
              .toList();
          historyJson = jsonEncode(items);
          return true;
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(speechChannel, (call) async {
      speechMethods.add(call.method);
      switch (call.method) {
        case 'initialize':
        case 'has_permission':
          return true;
        case 'listen':
          speechListenCalls++;
          return true;
        case 'stop':
        case 'cancel':
          return null;
        case 'locales':
          return <String>[];
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(speechChannel, null);
  });

  testWidgets(
      'native search uses the extracted phrase and ignores stale replies',
      (tester) async {
    SharedPreferences.setMockInitialValues({'account_welcome_seen': true});
    nativeSearches = {};
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextField), 'find assignment');
    await tester.pump(const Duration(milliseconds: 400));
    expect(nativeSearches!.containsKey('assignment'), isTrue);
    await tester.enterText(find.byType(TextField), 'project');
    await tester.pump(const Duration(milliseconds: 400));
    // The latest query must start before the obsolete native request resolves.
    // This guards against reintroducing a global in-flight gate.
    expect(nativeSearches!.containsKey('project'), isTrue);
    nativeSearches!['assignment']!.complete([
      {
        'name': 'Stale syllabus.pdf',
        'type': 'application/pdf',
        'path': 'stale',
        'content': 'syllabus course outline',
      }
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    nativeSearches!['project']!.complete([]);
    await tester.pump();
    await waitForDocumentResults(tester);
    expect(find.text('Project plan.pdf'), findsOneWidget);
    expect(find.text('Stale syllabus.pdf'), findsNothing);
    await stopVoiceSession(tester);
  });

  testWidgets('late results do not reorder cards after reading starts',
      (tester) async {
    SharedPreferences.setMockInitialValues({'account_welcome_seen': true});
    nativeSearches = {};
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextField), 'project');
    await tester.pump(const Duration(milliseconds: 400));
    await waitForDocumentResults(tester);
    final scroll = tester.element(find.byType(CustomScrollView).first);
    ScrollStartNotification(
      metrics: FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: 500,
          pixels: 10,
          viewportDimension: 400,
          axisDirection: AxisDirection.down,
          devicePixelRatio: 1),
      context: scroll,
      dragDetails: DragStartDetails(),
    ).dispatch(scroll);
    nativeSearches!['project']!.complete([
      {
        'name': 'Project newest.pdf',
        'type': 'application/pdf',
        'path': 'newest',
        'content': 'project plan',
        'modified': '999999',
      }
    ]);
    for (var i = 0;
        i < 40 && find.text('Show updated results').evaluate().isEmpty;
        i++) {
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    await tester.pump();
    expect(find.text('Show updated results'), findsOneWidget);
    expect(find.text('Project newest.pdf'), findsNothing);
    await tester.tap(find.text('Show updated results'));
    await tester.pump();
    expect(find.text('Project newest.pdf'), findsOneWidget);
    await stopVoiceSession(tester);
  });

  testWidgets('empty native reply clears the search progress status',
      (tester) async {
    SharedPreferences.setMockInitialValues({'account_welcome_seen': true});
    nativeSearches = {};
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextField), 'zzqnomatch7329');
    await tester.pump(const Duration(milliseconds: 400));
    await waitForDocumentResults(tester);
    nativeSearches!['zzqnomatch7329']!.complete([]);
    await tester.pump();
    await waitForDocumentResults(tester);
    await tester.pump();
    expect(find.text('Searching files…'), findsNothing);
    expect(find.text('No matching local results found.'), findsOneWidget);
    await stopVoiceSession(tester);
  });

  testWidgets('returning from a document keeps the current file results',
      (tester) async {
    SharedPreferences.setMockInitialValues({'account_welcome_seen': true});
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));

    await tester.enterText(find.byType(TextField), 'project');
    await tester.pump(const Duration(milliseconds: 400));
    await waitForDocumentResults(tester);
    await tester.tap(find.text('Project plan.pdf'));
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'project',
    );
    expect(find.text('Project plan.pdf'), findsOneWidget);
    await stopVoiceSession(tester);
  });

  testWidgets('a new query does not inherit the previous no-match decision',
      (tester) async {
    SharedPreferences.setMockInitialValues({'account_welcome_seen': true});
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextField), 'project');
    await tester.pump(const Duration(milliseconds: 400));
    await waitForDocumentResults(tester);
    expect(find.text('Project plan.pdf'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'syllabus');
    await tester.pump(const Duration(milliseconds: 130));
    expect(find.text('No matching local results found.'), findsNothing);
    await stopVoiceSession(tester);
  });

  testWidgets('search renders while startup sources are still loading',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'account_welcome_seen': true});
    final sources = Completer<Map<String, Object>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getInitialData') return sources.future;
      return null;
    });

    await tester.pumpWidget(const SmartSearchApp());
    await tester.pump();

    expect(sources.isCompleted, isFalse);
    expect(find.text('Apex AI'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('hello'), findsOneWidget);

    sources.complete({'history': '[]', 'apps': [], 'contacts': []});
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  });

  testWidgets('submitting an ordinary question renders a grounded chat answer',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'account_welcome_seen': true});
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));

    await tester.enterText(
      find.byType(TextField),
      'what is in my project plan',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await waitForDocumentResults(tester);
    await tester.tap(find.byTooltip('Send request'));
    await tester.pump();

    expect(find.text('From your device'), findsOneWidget);
    expect(find.textContaining('relevant file'), findsOneWidget);
    expect(find.textContaining('Evidence: Project plan.pdf'), findsOneWidget);
    await stopVoiceSession(tester);
  });

  testWidgets('startup work and decoration wait for the first rasterized frame',
      (WidgetTester tester) async {
    final firstFrame = Completer<void>();
    binding.firstFrameReady = firstFrame.future;
    SharedPreferences.setMockInitialValues({'account_welcome_seen': true});
    final startupCalls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      startupCalls.add(call.method);
      return null;
    });

    await tester.pumpWidget(const SmartSearchApp());
    await tester.pump();
    expect(find.text('Apex AI'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(startupCalls, isEmpty);
    expect(
      tester.widget<NexaVisualEffects>(find.byType(NexaVisualEffects)).enabled,
      isFalse,
    );
    expect(
      tester
          .widgetList<BackdropFilter>(find.byType(BackdropFilter))
          .every((filter) => !filter.enabled),
      isTrue,
    );

    firstFrame.complete();
    await tester.pumpAndSettle();
    expect(startupCalls, contains('getInitialData'));
    expect(
      tester.widget<NexaVisualEffects>(find.byType(NexaVisualEffects)).enabled,
      isTrue,
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  });

  testWidgets('imported Gmail notes are labeled by subject',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'account_welcome_seen': true});
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add context'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import class notes'));
    await tester.pumpAndSettle();
    expect(find.text('unit1.pdf'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Subject'), 'Data Compression');
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(
        platformCalls.any((call) =>
            call.method == 'importSharedDocuments' &&
            (call.arguments as Map)['subject'] == 'Data Compression'),
        isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an imported copy can be removed without deleting the original',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'account_welcome_seen': true});
    const importedPath =
        'content://com.example.smart_search_app.imported_documents/imported_notes/unit1.pdf';
    nativeDocuments = [
      {
        'name': 'Data Compression notes - unit1.pdf',
        'type': 'application/pdf',
        'path': importedPath,
        'folder': 'Imported notes/',
      },
    ];
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextField), 'Data Compression');
    await tester.pump(const Duration(milliseconds: 400));
    for (var attempt = 0;
        attempt < 40 &&
            find.text('Data Compression notes - unit1.pdf').evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.longPress(find.text('Data Compression notes - unit1.pdf'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove imported copy'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The original attachment stays where it was.'),
        findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(
        platformCalls.any((call) =>
            call.method == 'removeImportedDocument' &&
            (call.arguments as Map)['path'] == importedPath),
        isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('search controller follows replacement and unmount lifecycle',
      (WidgetTester tester) async {
    final firstFrame = Completer<void>();
    binding.firstFrameReady = firstFrame.future;
    final original = SearchScreenController();
    final replacement = SearchScreenController();
    const result = SearchResult(
      kind: ResultKind.app,
      title: 'WhatsApp',
      subtitle: 'Open app',
      icon: Icons.apps_rounded,
      packageName: 'com.whatsapp',
    );
    Widget host(SearchScreenController controller) => MaterialApp(
          home: Scaffold(
            body: SearchScreen(
              controller: controller,
              isDarkMode: true,
              themeMode: ThemeMode.dark,
              onSetThemeMode: (_) {},
              accountSync: null,
              onSignedIn: () async {},
              onOpenHistory: () {},
              onHistoryChanged: (_) {},
            ),
          ),
        );

    await original.openResult(result);
    expect(platformCalls, isEmpty);
    await tester.pumpWidget(host(original));
    expect(platformCalls, isEmpty);
    await tester.runAsync(() => original.openResult(result));
    expect(
        platformCalls.where((call) => call.method == 'openApp'), hasLength(1));

    await tester.pumpWidget(host(replacement));
    await original.openResult(result);
    expect(
        platformCalls.where((call) => call.method == 'openApp'), hasLength(1));
    await tester.runAsync(() => replacement.openResult(result));
    expect(
        platformCalls.where((call) => call.method == 'openApp'), hasLength(2));

    await tester.pumpWidget(const SizedBox.shrink());
    platformCalls.clear();
    await replacement.openResult(result);
    await replacement.clearHistory();
    firstFrame.complete();
    await tester.pump();
    expect(platformCalls.where((call) => call.method == 'openApp'), isEmpty);
    expect(platformCalls.where((call) => call.method == 'removeFromHistory'),
        isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('matched apps and files load artwork only after startup',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'account_welcome_seen': true});
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));

    expect(artworkCalls, isEmpty);
    await tester.enterText(find.byType(TextField), 'WhatsApp');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(
      artworkCalls.where((call) => call.method == 'getAppIcon'),
      isNotEmpty,
    );

    await tester.enterText(find.byType(TextField), 'project');
    await tester.pump(const Duration(milliseconds: 400));
    await waitForDocumentResults(tester);
    await tester.pump();
    expect(
      artworkCalls.where((call) => call.method == 'getDocumentPreview'),
      isNotEmpty,
    );
    await stopVoiceSession(tester);
  });

  testWidgets('phone layouts keep search and supporting navigation usable',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final size in [
      const Size(320, 568),
      const Size(390, 844),
      const Size(768, 1024)
    ]) {
      tester.view.physicalSize = size;
      SharedPreferences.setMockInitialValues({'account_welcome_seen': true});
      await tester.pumpWidget(const SmartSearchApp());
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Home at $size');
      expect(
          tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
          isFalse);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Appearance'), findsOneWidget);
      await tester.scrollUntilVisible(
          find.textContaining('Scanned files:'), 220,
          scrollable: find.byType(Scrollable).last);
      await tester.pumpAndSettle();
      expect(find.text('Scanned files: 12 of 40'), findsOneWidget);
      expect(find.text('Scanning paused while you search'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'Settings at $size');
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('History'));
      await tester.pumpAndSettle();
      expect(find.text('No history yet'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'History at $size');
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'project');
      await tester.pump(const Duration(seconds: 1));
      await waitForDocumentResults(tester);
      expect(find.text('Project plan.pdf'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'Results at $size');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  testWidgets('file indexing settings send all four indexing speed modes',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'account_welcome_seen': true});
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));

    await openFileIndexingSettings(tester);
    expect(find.text('Scan schedule'), findsOneWidget);

    for (final choice in <String, String>{
      'Ultra fast': 'ultra_fast',
      'Fast': 'fast',
      'Balanced': 'balanced',
      'Slow': 'slow',
    }.entries) {
      final radio = find.ancestor(
        of: find.text(choice.key),
        matching: find.byType(RadioListTile<String>),
      );
      await tester.tap(radio);
      await tester.pump();
      await tester.pump();
    }

    final calls = platformCalls
        .where((call) => call.method == 'setDocumentIndexMode')
        .toList();
    expect(
      calls.map((call) => call.arguments),
      [
        {'mode': 'ultra_fast'},
        {'mode': 'fast'},
        {'mode': 'balanced'},
        {'mode': 'slow'},
      ],
    );
    expect(find.text('Indexing preference saved.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('scan schedule saves the selected time window through native API',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'account_welcome_seen': true});
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));

    await openFileIndexingSettings(tester);
    final chooseTime = find.text('Choose time');
    await tester.scrollUntilVisible(
      chooseTime,
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(chooseTime);
    await tester.pumpAndSettle();
    expect(find.text('Choose scan start time'), findsOneWidget);

    // Confirm the deterministic initial time (midnight) to exercise the
    // bridge without relying on clock-face coordinates in a widget test.
    await tester.tap(find.text('OK'));
    await tester.pump();

    final calls = platformCalls
        .where((call) => call.method == 'setDocumentIndexSchedule')
        .toList();
    expect(calls, hasLength(1));
    expect(calls.single.arguments, {
      'startMinute': 0,
      'endMinute': 7 * 60,
    });
    expect(find.text('Scan schedule saved.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('restart scan waits for confirmation before invoking native API',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'account_welcome_seen': true});
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));

    await openFileIndexingSettings(tester);
    final restart = find.text('Restart scan from beginning');
    await tester.scrollUntilVisible(
      restart,
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(restart);
    // Restarting intentionally shows an indeterminate progress bar under the
    // confirmation dialog, so a bounded pump is more appropriate than
    // pumpAndSettle here.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Restart the file scan?'), findsOneWidget);
    expect(
      platformCalls.where((call) => call.method == 'restartDocumentIndexing'),
      isEmpty,
    );

    await tester.tap(find.text('Restart scan'));
    await tester.pump();
    await tester.pump();

    expect(
      platformCalls.where((call) => call.method == 'restartDocumentIndexing'),
      hasLength(1),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('full-screen voice can hand its transcript back to typing',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'account_welcome_seen': true,
      'nexa_spoken_responses': false,
    });
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await pressVoiceButton(tester);
    expect(find.text('Apex Voice'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await sendSpeechCallback(
        'textRecognition',
        jsonEncode({
          'alternates': [
            {
              'recognizedWords': 'find my notes',
              'recognizedPhrases': null,
              'confidence': 0.9
            }
          ],
          'resultType': 1,
        }));
    await tester.pump();
    expect(find.text('find my notes'), findsOneWidget);
    await tester.tap(find.byTooltip('Switch to typing'));
    await flushVoiceTasks(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Apex Voice'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'find my notes');
    expect(directCalls, 0);
    await stopVoiceSession(tester);
  });

  testWidgets('search shows contact, phone, app, document, and web results',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with Apple'), findsOneWidget);
    await tester.tap(find.text('Continue without an account'));
    await tester.pumpAndSettle();

    expect(find.text('Apex AI'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'arpan');
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('Arpan'), findsOneWidget);
    expect(find.text('Call'), findsOneWidget);
    expect(find.text('Message'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField),
      '9876543210',
    );
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('Call'), findsOneWidget);
    expect(find.text('Message'), findsOneWidget);
    expect(find.text('WhatsApp'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'whatsapp');
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('WhatsApp'), findsAtLeastNWidgets(1));
    expect(find.text('Search the web for "whatsapp"'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'project');
    await tester.pump(const Duration(milliseconds: 700));

    await flushVoiceTasks(tester);
    await waitForDocumentResults(tester);
    expect(find.text('Project plan.pdf'), findsOneWidget);
  });

  testWidgets('ordinary searches do not show weak phonetic contact matches',
      (WidgetTester tester) async {
    contacts = [
      {'name': 'Sumanta Basak', 'phone': '919404651089'},
    ];
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue without an account'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'assessment');
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('Call Sumanta Basak'), findsNothing);
    expect(find.text('Search the web for "assessment"'), findsOneWidget);
  });

  testWidgets('history restores action icons from their saved destinations',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: HistoryScreen(
      history: [
        for (final scheme in ['tel', 'sms', 'whatsapp', 'music'])
          SearchResult(
              kind: ResultKind.action,
              title: scheme,
              subtitle: '',
              icon: Icons.bolt,
              url: Uri(scheme: scheme, path: 'example')),
      ],
      onClearAll: () {},
      onItemTap: (_) {},
      onBack: () {},
    ))));
    await tester.pumpAndSettle();
    for (final icon in [
      Icons.call_rounded,
      Icons.sms_rounded,
      Icons.chat_rounded,
      Icons.music_note_rounded
    ]) {
      expect(find.byIcon(icon), findsOneWidget);
    }
    expect(find.byIcon(Icons.bolt), findsNothing);
  });

  testWidgets('song actions and history re-open the original action',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue without an account'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'play blue sky');
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Play "blue sky" on Spotify'), findsOneWidget);
    expect(find.text('Play "blue sky" on Apple Music'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'starlight');
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Play "starlight" on Spotify'), findsNothing);
    expect(find.text('Search the web for "starlight"'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'arpan');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('Call'));
    await tester.pumpAndSettle();
    expect(directCalls, 1);

    await tester.tap(find.byIcon(Icons.history_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Call Arpan'), findsOneWidget);

    await tester.tap(find.text('Call Arpan'));
    await tester.pumpAndSettle();
    expect(directCalls, 2);
  });

  testWidgets('clearing history through the app shell also clears conversation',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'account_welcome_seen': true,
      'nexa_local_conversation_v1': '[]',
    });
    historyJson = jsonEncode([
      {
        'kind': 'action',
        'title': 'Call Arpan',
        'subtitle': 'Direct call',
        'extra': 'tel:1234567890',
      },
    ]);
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.history_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Call Arpan'), findsOneWidget);

    await tester.tap(find.byTooltip('History options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear history'));
    await tester.pumpAndSettle();

    expect(jsonDecode(historyJson), isEmpty);
    expect(find.text('No history yet'), findsOneWidget);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.containsKey('nexa_local_conversation_v1'), isFalse);
  });

  testWidgets('repeating an action refreshes and promotes its history entry',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue without an account'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'arpan');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('Call'));
    await tester.pumpAndSettle();

    final firstTimestamp = (jsonDecode(historyJson) as List).first['timestamp'];
    await tester.enterText(find.byType(TextField), 'whatsapp');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('WhatsApp').first);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'arpan');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('Call'));
    await tester.pumpAndSettle();

    final history = jsonDecode(historyJson) as List<dynamic>;
    expect(history.first['title'], 'Call Arpan');
    expect(history.first['usageCount'], 2);
    expect(history.first['timestamp'], isNot(firstTimestamp));
  });

  testWidgets('submitting an exact call command places one direct call',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue without an account'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'call Arpan');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(directCalls, 1);
  });

  testWidgets('submitting a conversational call request uses local intent',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue without an account'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      'I was wondering if you could give Arpan a call',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(directCalls, 1);
    expect(lastDirectCall, '8788029538');
  });

  testWidgets('voice calls wait for spoken confirmation before executing',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'account_welcome_seen': true,
      'nexa_spoken_responses': false,
    });
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    await pressVoiceButton(tester);
    // SpeechToText caches successful initialization across widget instances.
    expect(SpeechToText().isAvailable, isTrue);
    expect(speechListenCalls, 1);
    await sendFinalSpeech('call Arpan');
    await flushVoiceTasks(tester);

    expect(directCalls, 0);
    final visibleText = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .whereType<String>()
        .join(' | ');
    expect(find.textContaining('Call Arpan?'), findsOneWidget,
        reason: visibleText);

    await sendFinalSpeech('yes');
    await flushVoiceTasks(tester);

    expect(directCalls, 1);
    expect(lastDirectCall, '8788029538');
    expect(speechListenCalls, greaterThanOrEqualTo(3));
    await stopVoiceSession(tester);
  });

  testWidgets('voice remains active for a correction after showing results',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'account_welcome_seen': true,
      'nexa_spoken_responses': false,
    });
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    await pressVoiceButton(tester);
    expect(speechListenCalls, 1);
    await sendFinalSpeech('find document project');
    await flushVoiceTasks(tester);

    await waitForDocumentResults(tester);
    expect(find.text('Project plan.pdf'), findsOneWidget);
    expect(find.textContaining('Listening for a correction'), findsOneWidget);
    expect(speechListenCalls, greaterThanOrEqualTo(2));

    await sendFinalSpeech('no I meant plan');
    await flushVoiceTasks(tester);

    await waitForDocumentResults(tester);
    expect(find.text('Project plan.pdf'), findsOneWidget);
    expect(find.textContaining('Listening for a correction'), findsOneWidget);
    await stopVoiceSession(tester);
  });

  testWidgets('cancelling a pending voice call does not execute it',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'account_welcome_seen': true,
      'nexa_spoken_responses': false,
    });
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();

    await pressVoiceButton(tester);
    expect(speechListenCalls, 1);
    await sendFinalSpeech('call Arpan');
    await flushVoiceTasks(tester);
    await sendFinalSpeech('cancel');
    await flushVoiceTasks(tester);

    expect(directCalls, 0);
    expect(find.textContaining('Listening for a correction'), findsOneWidget);
    await stopVoiceSession(tester);
  });

  testWidgets('duplicate exact contact names require a choice',
      (WidgetTester tester) async {
    contacts = [
      {'name': 'Rahul', 'phone': '9000000001'},
      {'name': 'Rahul', 'phone': '9000000002'},
    ];
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue without an account'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'call Rahul');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(directCalls, 0);
    // The Search/Chats navigation reduces the viewport. Both candidates remain
    // available in the scrollable result list; neither may be auto-selected.
    await tester.drag(
        find.byType(CustomScrollView).last, const Offset(0, -160));
    await tester.pump();
    expect(find.text('Call Rahul'), findsNWidgets(2));
    expect(find.textContaining('Choose the correct number'), findsOneWidget);
  });

  testWidgets('a spoken qualifier resolves a pending contact choice',
      (WidgetTester tester) async {
    contacts = [
      {'name': 'Anish S', 'phone': '9000000003'},
      {'name': 'Anish M-I-C-V-I-T', 'phone': '9000000004'},
    ];
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue without an account'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'call Anish');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(directCalls, 0);

    await tester.enterText(find.byType(TextField), 'the MICVIT one');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(directCalls, 1);
    expect(lastDirectCall, '9000000004');
  });

  testWidgets('a call-wrapped ordinal resolves a pending contact choice',
      (WidgetTester tester) async {
    contacts = [
      {'name': 'Anish MIC', 'phone': '9000000003'},
      {'name': 'Anish Mishra', 'phone': '9000000004'},
    ];
    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue without an account'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'call Anish');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(directCalls, 0);

    await tester.enterText(find.byType(TextField), 'call the second one');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(directCalls, 1);
    expect(lastDirectCall, '9000000004');
  });

  testWidgets('a follow-up can choose the contact called most often',
      (WidgetTester tester) async {
    contacts = [
      {'name': 'Anish MIC', 'phone': '9000000003'},
      {'name': 'Anish Mishra', 'phone': '9000000004'},
      {'name': 'Anish Nigam', 'phone': '9000000005'},
    ];
    SharedPreferences.setMockInitialValues({
      'contact_selection_stats': jsonEncode({
        '9000000003': {
          'count': 12,
          'lastSelectedAt': '2026-07-23T10:00:00.000',
        },
        '9000000004': {
          'count': 3,
          'lastSelectedAt': '2026-07-20T10:00:00.000',
        },
        '9000000005': {
          'count': 1,
          'lastSelectedAt': '2026-07-18T10:00:00.000',
        },
      }),
    });

    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue without an account'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'call Anish');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(directCalls, 0);

    await tester.enterText(
      find.byType(TextField),
      'call the one I call most of the time',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(directCalls, 1);
    expect(lastDirectCall, '9000000003');
  });

  testWidgets('a single command can call the most-used matching contact',
      (WidgetTester tester) async {
    contacts = [
      {'name': 'Anish MIC', 'phone': '9000000003'},
      {'name': 'Anish Mishra', 'phone': '9000000004'},
    ];
    SharedPreferences.setMockInitialValues({
      'contact_selection_stats': jsonEncode({
        '9000000003': {
          'count': 9,
          'lastSelectedAt': '2026-07-23T10:00:00.000',
        },
        '9000000004': {
          'count': 2,
          'lastSelectedAt': '2026-07-20T10:00:00.000',
        },
      }),
    });

    await tester.pumpWidget(const SmartSearchApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue without an account'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      'call the most called Anish',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(directCalls, 1);
    expect(lastDirectCall, '9000000003');
  });
}
