import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_search_app/features/history/data/history_entry_codec.dart';
import 'package:smart_search_app/features/search/models/search_result.dart';

void main() {
  for (final kind in ResultKind.values) {
    test('$kind restores the saved destination through both history paths', () {
      final entry = {
        'kind': kind.name,
        'title': 'Saved result',
        'subtitle': 'Saved detail',
        'extra': switch (kind) {
          ResultKind.app => 'com.example.app',
          ResultKind.document => 'content://documents/42',
          ResultKind.action => 'tel:+911234567890',
          ResultKind.web => 'https://example.com/search?q=flutter',
        },
        'timestamp': '2026-09-16T10:15:00.000Z',
        'usageCount': 7,
        'icon': 'cached-icon',
      };
      for (final decode in [
        HistoryEntryCodec.decode,
        HistoryEntryCodec.decodeInitialSnapshot,
      ]) {
        final result = decode(entry);
        expect(result.kind, kind);
        expect(result.title, entry['title']);
        expect(result.subtitle, entry['subtitle']);
        expect(result.usageCount, 7);
        expect(result.iconBase64, 'cached-icon');
        expect(result.timestamp, DateTime.utc(2026, 9, 16, 10, 15));
        final encoded = HistoryEntryCodec.encode(
          result,
          query: 'repeat search',
          timestamp: result.timestamp!,
        );
        expect(encoded['extra'], entry['extra']);
        expect(encoded['kind'], entry['kind']);
        expect(encoded['query'], 'repeat search');
        expect(encoded['timestamp'], entry['timestamp']);
      }
    });
  }

  test('old unknown kinds and invalid timestamps remain readable', () {
    final result = HistoryEntryCodec.decode({
      'kind': 'retired-kind',
      'timestamp': 'not a date',
      'extra': 'https://example.com',
    });
    expect(result.kind, ResultKind.web);
    expect(result.icon, Icons.public_rounded);
    expect(result.timestamp, isNull);
    expect(result.title, isEmpty);
    expect(result.url, Uri.parse('https://example.com'));
    expect(result.usageCount, 0);
  });

  test('empty snapshot destinations retain their original decoding semantics',
      () {
    final entry = {'kind': 'web', 'extra': ''};
    expect(HistoryEntryCodec.decode(entry).url, isNull);
    expect(HistoryEntryCodec.decodeInitialSnapshot(entry).url, Uri());
  });

  test('only app history substitutes the fetched preview for its cached icon',
      () {
    for (final kind in ResultKind.values) {
      final result = SearchResult(
        kind: kind,
        title: 'Result',
        subtitle: '',
        icon: Icons.search,
        iconBase64: 'original-icon',
        previewBase64: 'fetched-preview',
      );
      final encoded = HistoryEntryCodec.encode(
        result,
        query: 'query',
        timestamp: DateTime.utc(2026),
      );
      expect(encoded['icon'],
          kind == ResultKind.app ? 'fetched-preview' : 'original-icon');
    }
  });
}
