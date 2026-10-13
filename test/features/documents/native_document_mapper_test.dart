import 'package:flutter_test/flutter_test.dart';
import 'package:smart_search_app/features/documents/data/native_document_mapper.dart';
import 'package:smart_search_app/features/documents/domain/document_intelligence.dart';

void main() {
  test(
      'legacy index rows retain delimited lists, metadata, and timestamp units',
      () {
    final document = documentFromPlatformMap({
      'name': 'ticket.pdf',
      'path': 'content://documents/42',
      'type': 'application/pdf',
      'keywords': ' travel | | Delhi ',
      'signals': 'flight|ticket',
      'retrievalReasons': 'destination|date',
      'metadata': '{"destination":"Delhi","year":2026}',
      'modified': '1700000000',
      'lastOpened': '1700000100000',
      'embedding': 'legacy-vector',
    });

    expect(document.keywords, ['travel', 'Delhi']);
    expect(document.signals, ['flight', 'ticket']);
    expect(document.graphReasons, ['destination', 'date']);
    expect(document.metadata, {'destination': 'Delhi', 'year': '2026'});
    expect(document.modifiedAt?.millisecondsSinceEpoch, 1700000000000);
    expect(document.lastOpened?.millisecondsSinceEpoch, 1700000100000);
    expect(document.embedding, 'legacy-vector');
    expect(document.path, 'content://documents/42');
  });

  test(
      'current native rows prefer passage embeddings and explicit graph reasons',
      () {
    final document = documentFromPlatformMap({
      'keywords': [' GPU ', '', 'CUDA'],
      'headings': ['Introduction', ' Architecture '],
      'chunkEmbedding': 'passage-vector',
      'embedding': 'legacy-vector',
      'fileEmbedding': 'file-vector',
      'graphReasons': ['subject'],
      'retrievalReasons': ['legacy-reason'],
      'metadata': {'pages': 4, 'subject': 'GPU'},
      'graphScore': 0.75,
      'ftsRank': 2,
      'graphRank': 1,
      'usageCount': 3,
    });

    expect(document.keywords, ['GPU', 'CUDA']);
    expect(document.headings, ['Introduction', 'Architecture']);
    expect(document.embedding, 'passage-vector');
    expect(document.fileEmbedding, 'file-vector');
    expect(document.graphReasons, ['subject']);
    expect(document.metadata, {'pages': '4', 'subject': 'GPU'});
    expect(document.graphScore, 0.75);
    expect(document.ftsRank, 2);
    expect(document.graphRank, 1);
    expect(document.usageCount, 3);
  });

  test('missing or malformed optional fields preserve existing safe defaults',
      () {
    final document = documentFromPlatformMap({
      'metadata': 'not JSON',
      'bytes': 'invalid',
      'categoryConfidence': 'invalid',
      'modified': 'invalid',
      'lastOpened': 0,
    });

    expect(document.name, '');
    expect(document.type, 'Document');
    expect(document.path, isNull);
    expect(document.metadata, isEmpty);
    expect(document.keywords, isEmpty);
    expect(document.extractedBytes, 0);
    expect(document.category, 'document');
    expect(document.categoryConfidence, 0.25);
    expect(document.modifiedAt, isNull);
    expect(document.lastOpened, isNull);
  });

  test('current profile metadata survives native decoding without re-inference',
      () {
    final document = documentFromPlatformMap({
      'name': 'random.pdf',
      'category': 'travel',
      'categoryConfidence': 0.95,
      'summary': 'Trip to Delhi',
      'profileVersion': DocumentIntelligence.profileVersion,
      'keywords': ['flight'],
      'metadata': {'destination': 'Delhi'},
    });

    expect(document.profile.category, 'travel');
    expect(document.profile.summary, 'Trip to Delhi');
    expect(document.profile.confidence, 0.95);
    expect(document.profile.metadata['destination'], 'Delhi');
  });
}
