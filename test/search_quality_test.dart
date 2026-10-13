import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_search_app/features/documents/data/document_search_service.dart';
import 'package:smart_search_app/features/documents/domain/document_intelligence.dart';
import 'package:smart_search_app/features/documents/domain/document_search_worker.dart';

void main() {
  Map<String, dynamic> doc(String name, String content, {int modified = 1}) => {
        'name': name,
        'content': content,
        'type': 'application/pdf',
        'path': name,
        'embedding': '',
        'modified': modified,
      };
  final documents = [
    doc('Syllabus.pdf', 'Syllabus and course outline for computer science.'),
    doc('Untitled.png', 'Type your notes here. Tutorial ideas.', modified: 999),
    doc('Train ticket.pdf', 'IRCTC train ticket PNR journey coach berth.'),
    doc('Assignment.pdf', 'Digital assignment homework coursework.'),
    doc('Meeting.pdf', 'We discussed the syllabus during the meeting.'),
  ];
  for (final subject in ['GPU', 'Python', 'HealthView', 'CUDA']) {
    test(
        '$subject notes requires the subject despite category and graph boosts',
        () {
      final ranked = rankDocumentBatch({
        'query': '$subject notes',
        'documents': [
          doc('$subject notes.pdf',
              '$subject lecture notes and study material'),
          doc('scan.pdf', 'Lecture notes about $subject'),
          {
            ...doc('Biology.pdf', 'Biology lecture notes and syllabus'),
            'graphScore': 4.0,
            'graphReasons': <String>['Classified as study material'],
            'usageCount': 999,
          },
          {
            ...doc('Shopping.pdf', 'Grocery shopping list'),
            'graphScore': 2.0,
            'graphReasons': <String>['Often opened with another matching file'],
          },
        ],
      });
      expect(
          ranked.map((row) => row['name']), ['$subject notes.pdf', 'scan.pdf']);
    });
  }
  test('GPU is a whole subject token, not a substring or short typo', () {
    final ranked = rankDocumentBatch({
      'query': 'GPU notes',
      'documents': [
        doc('CPU notes.pdf', 'CPU lecture notes'),
        doc('gpupdate.txt', 'gpupdate lecture notes'),
      ],
    });
    expect(ranked, isEmpty);
  });
  test('GPU subject accepts CUDA concept evidence without a literal GPU token',
      () {
    final ranked = rankDocumentBatch({
      'query': 'GPU notes',
      'documents': [
        doc('Module 4.pdf',
            'CUDA kernels, warps and coalesced memory access lecture notes'),
        doc('CPU notes.pdf', 'CPU cache and malloc lecture notes'),
      ],
    });
    expect(ranked.map((row) => row['name']), ['Module 4.pdf']);
  });
  test('reciprocal rank fusion combines keyword and semantic positions', () {
    final ranked = rankDocumentBatch({
      'query': 'GPU notes',
      'embedding': <int>[127, 0],
      'documents': [
        {
          ...doc('Generic GPU.pdf', 'GPU lecture notes'),
          'ftsRank': 1,
          'embedding': base64Encode(<int>[0, 127]),
        },
        {
          ...doc('CUDA Optimization.pdf',
              'CUDA kernel and coalesced memory lecture notes'),
          'ftsRank': 2,
          'embedding': base64Encode(<int>[127, 0]),
        },
      ],
    });
    expect(ranked.first['name'], 'CUDA Optimization.pdf');
    expect(ranked.first['semanticSimilarity'], greaterThan(0.9));
  });
  test('multiword query snippet shows the matching subject deep in content',
      () {
    final ranked = rankDocumentBatch({
      'query': 'GPU notes',
      'documents': [
        doc('Lecture.pdf',
            '${'Introduction to lecture notes. ' * 50}GPU memory architecture')
      ],
    });
    expect(ranked, hasLength(1));
    expect(ranked.single['excerpt'], contains('GPU memory architecture'));
  });
  for (final example in {
    'syllabus': 'Syllabus.pdf',
    'train ticket': 'Train ticket.pdf',
    'assignment': 'Assignment.pdf',
    'assignmen': 'Assignment.pdf',
  }.entries) {
    test('best result for ${example.key}', () {
      final ranked =
          rankDocumentBatch({'query': example.key, 'documents': documents});
      expect(ranked.first['name'], example.value);
      expect(ranked.any((d) => d['name'] == 'Untitled.png'), isFalse);
    });
  }
  test('newer equivalent files win ties and all matches remain available', () {
    final many = List.generate(100,
        (i) => doc('Syllabus.pdf', 'Syllabus course outline', modified: i));
    final ranked = rankDocumentBatch({'query': 'syllabus', 'documents': many});
    expect(ranked, hasLength(100));
    expect(ranked.first['modified'], 99);
  });
  test('history and high embedding similarity cannot admit unrelated files',
      () {
    final profile = DocumentIntelligence.infer(
        name: 'Kitchen.pdf',
        mimeType: 'application/pdf',
        content: 'Kitchen cupboard measurements');
    expect(
        DocumentIntelligence.score(
            query: 'syllabus',
            name: 'Kitchen.pdf',
            mimeType: 'application/pdf',
            content: 'Kitchen cupboard measurements',
            profile: profile,
            positiveFeedback: 10000,
            semanticSimilarity: 1),
        0);
  });
  test('large candidate batch excludes unrelated files', () {
    final many = List.generate(5000, (i) => doc('Note $i.txt', 'Grocery list'));
    many.add(doc('Syllabus.pdf', 'Syllabus and course outline'));
    final watch = Stopwatch()..start();
    final ranked = rankDocumentBatch({'query': 'syllabus', 'documents': many});
    watch.stop();
    expect(ranked, hasLength(1));
    expect(ranked.single['name'], 'Syllabus.pdf');
    // Diagnostic only: host timing is not a phone responsiveness guarantee.
    // ignore: avoid_print
    print('5001-candidate host scoring: ${watch.elapsedMilliseconds} ms');
  });
  test('prepared data is reused and refreshed after content changes', () {
    final ranker = DocumentRanker();
    final rows = [doc('Notes.pdf', 'Syllabus course outline')];
    expect(ranker.rank({'query': 'syllabus', 'documents': rows}), hasLength(1));
    expect(ranker.preparedCount, 1);
    expect(ranker.rank({'query': 'outline', 'documents': rows}), hasLength(1));
    expect(ranker.preparedCount, 1);
    rows[0] = doc('Notes.pdf', 'Kitchen cupboard measurements');
    expect(ranker.rank({'query': 'syllabus', 'documents': rows}), isEmpty);
  });
  test('explicit not-relevant feedback excludes an otherwise strong match', () {
    final ranked = rankDocumentBatch({
      'query': 'syllabus',
      'documents': documents,
      'excludedPaths': <String>['Syllabus.pdf']
    });
    expect(ranked.any((row) => row['name'] == 'Syllabus.pdf'), isFalse);
  });
  test('knowledge graph can admit a relationship-only match', () {
    final ranked = rankDocumentBatch({
      'query': 'files related to cuda project',
      'documents': [
        {
          ...doc('Benchmark.csv', 'Numbers without literal query terms'),
          'graphScore': 0.8,
          'graphReasons': <String>['Often opened with CUDA notes.pdf'],
        },
      ],
    });

    expect(ranked, hasLength(1));
    expect(ranked.single['name'], 'Benchmark.csv');
    expect(
      ranked.single['graphReasons'],
      contains('Often opened with CUDA notes.pdf'),
    );
  });
  test('usage is a bounded boost and cannot admit unrelated files alone', () {
    final ranked = rankDocumentBatch({
      'query': 'syllabus',
      'documents': [
        {
          ...doc('Kitchen.pdf', 'Kitchen cupboard measurements'),
          'usageCount': 1000,
          'lastOpened': DateTime.now().millisecondsSinceEpoch,
        },
        doc('Syllabus.pdf', 'Syllabus and course outline'),
      ],
    });

    expect(ranked.map((row) => row['name']), ['Syllabus.pdf']);
  });
  test(
      'supported syllabus synonyms follow literal matches and exclude generic notes',
      () {
    final ranked = rankDocumentBatch({
      'query': 'syllabus',
      'documents': [
        doc('Course.pdf', 'Curriculum and course outline for computer science'),
        doc('Syllabus.pdf', 'Syllabus for computer science'),
        doc('Notes.pdf', 'Tutorial ideas and lecture notes'),
      ]
    });
    expect(ranked.map((row) => row['name']), ['Syllabus.pdf', 'Course.pdf']);
  });
  test('persistent worker supports sequential queries and disposal', () async {
    final service = DocumentSearchService();
    try {
      final first =
          await service.rank({'query': 'syllabus', 'documents': documents});
      expect(first.first['name'], 'Syllabus.pdf');
      final second =
          await service.rank({'query': 'train ticket', 'documents': documents});
      expect(second.first['name'], 'Train ticket.pdf');
    } finally {
      service.dispose();
    }
    await expectLater(
        service.rank({'query': 'syllabus', 'documents': documents}),
        throwsStateError);
  });
  test('disposing during worker startup resolves the outstanding request',
      () async {
    final service = DocumentSearchService();
    final pending = service.rank({'query': 'syllabus', 'documents': documents});
    final assertion = expectLater(pending, throwsStateError);
    service.dispose();
    await assertion;
  });
}
