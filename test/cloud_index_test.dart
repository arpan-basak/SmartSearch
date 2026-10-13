import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_search_app/core/platform/search_platform.dart';
import 'package:smart_search_app/core/storage/preference_keys.dart';
import 'package:smart_search_app/features/cloud_index/data/cloud_index_api.dart';
import 'package:smart_search_app/features/cloud_index/data/cloud_index_repository.dart';
import 'package:smart_search_app/features/cloud_index/data/cloud_index_store.dart';
import 'package:smart_search_app/features/cloud_index/domain/cloud_index_models.dart';
import 'package:smart_search_app/features/cloud_index/presentation/cloud_index_settings_screen.dart';
import 'package:smart_search_app/features/search/models/search_result.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> platformCalls;
  late CloudIndexRepository repository;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    platformCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(searchPlatformChannel, (call) async {
      platformCalls.add(call);
      switch (call.method) {
        case 'getDocumentIndex':
          return <Map<String, Object?>>[
            {
              'name': 'Thesis.pdf',
              'type': 'application/pdf',
              'path': 'content://media/1',
              'hash': 'file-hash',
              'size': '2048',
              'modified': '1700000000',
            }
          ];
        case 'getCloudSyncConditions':
          return <String, Object?>{
            'connected': true,
            'wifi': true,
            'charging': true,
          };
        case 'getDocumentStorageBreakdown':
          return <String, Object?>{};
      }
      return null;
    });
    repository = CloudIndexRepository(
      store: CloudIndexStore(),
      api: CloudIndexApi(
        baseUrl: 'https://worker.example',
        tokenProvider: () async => 'test-token',
        client: MockClient((request) async =>
            http.Response(jsonEncode({'ok': true, 'documentCount': 0}), 200)),
      ),
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(searchPlatformChannel, null);
  });

  testWidgets('Cloud Sync toggle requires consent and document selection',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: CloudIndexSettingsScreen(
        accountSync: null,
        repository: repository,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(find.text('Enable Apex Cloud Sync?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cloud-consent-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Choose documents to sync'), findsOneWidget);
    expect(
        platformCalls.any((call) => call.method == 'getDocumentIndex'), isTrue);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.byKey(const Key('cloud-document-selection-save')));
    await tester.pumpAndSettle();

    final saved = await repository.store.loadSettings();
    expect(saved.enabled, isTrue);
    expect(saved.consentGranted, isTrue);
    expect(saved.selectedDocumentIds, hasLength(1));
  });

  testWidgets('turning Cloud Sync off offers safe pause behavior',
      (tester) async {
    final initial = const CloudIndexSettings(
      enabled: true,
      consentGranted: true,
      phase: CloudSyncPhase.synced,
    );
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.cloudIndexSettings: jsonEncode(initial.toJson()),
    });
    await tester.pumpWidget(MaterialApp(
      home: CloudIndexSettingsScreen(
        accountSync: null,
        repository: repository,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(find.text('Pause cloud sync'), findsOneWidget);
    await tester.tap(find.byKey(const Key('cloud-disable-pause')));
    await tester.pumpAndSettle();
    final saved = await repository.store.loadSettings();
    expect(saved.paused, isTrue);
    expect(saved.phase, CloudSyncPhase.paused);
  });

  testWidgets('cloud-index deletion has a separate strong confirmation',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: CloudIndexSettingsScreen(
        accountSync: null,
        repository: repository,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Delete cloud index'), 400,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Delete cloud index'));
    await tester.pumpAndSettle();
    expect(find.text('Delete cloud index?'), findsOneWidget);
    expect(find.byKey(const Key('cloud-destructive-confirm')), findsOneWidget);
    expect(find.textContaining('Original files on your phone are not deleted'),
        findsOneWidget);
  });

  test('hybrid merge deduplicates cloud and local results by locator', () {
    const local = SearchResult(
      kind: ResultKind.document,
      title: 'Thesis.pdf',
      subtitle: 'PDF',
      icon: Icons.description,
      path: 'content://media/1',
      relevance: 0.7,
    );
    const cloud = SearchResult(
      kind: ResultKind.document,
      title: 'Thesis.pdf',
      subtitle: 'Cloud index',
      icon: Icons.cloud,
      path: 'content://media/1',
      documentId: 'opaque-id',
      relevance: 0.95,
    );
    final merged = mergeHybridResults([local], [cloud]);
    expect(merged, hasLength(1));
    expect(merged.single.path, local.path);
  });

  test('offline fallback keeps local results when cloud returns none', () {
    const local = SearchResult(
      kind: ResultKind.document,
      title: 'Offline note',
      subtitle: 'Available offline',
      icon: Icons.description,
    );
    expect(mergeHybridResults([local], const []), [local]);
  });

  test('missing original cloud hit stays visible but is not openable', () {
    const hit = CloudSearchHit(
      documentId: 'opaque-id',
      title: 'Deleted.pdf',
      snippet: 'Relevant indexed text',
      score: 0.9,
    );
    final result = hit.toSearchResult(null);
    expect(result.documentAvailability, DocumentAvailability.cloudIndex);
    expect(result.localOriginalAvailable, isFalse);
    expect(result.path, isNull);
    expect(result.subtitle, contains('Cloud index'));
  });

  test('local storage budget clamps and detects overflow', () {
    expect(const LocalBudgetPolicy(250).bytes, 250 * 1024 * 1024);
    expect(const LocalBudgetPolicy(1).bytes, 50 * 1024 * 1024);
    expect(
        const LocalBudgetPolicy(250).isExceededBy(251 * 1024 * 1024), isTrue);
  });
}
