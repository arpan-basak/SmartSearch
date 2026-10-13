import 'package:flutter_test/flutter_test.dart';
import 'package:smart_search_app/features/knowledge/domain/knowledge_answer.dart';

void main() {
  test('answer is grounded in the supplied local evidence', () {
    final answer = KnowledgeAnswerComposer.compose(
      'What is related to the CUDA project?',
      const [
        KnowledgeEvidence(
          title: 'CUDA notes.pdf',
          summary: 'Kernel profiling notes and launch configuration.',
          folder: 'Documents/Research/',
          reasons: ['Mentions CUDA', 'Often opened with another matching file'],
        ),
        KnowledgeEvidence(
          title: 'GPU results.csv',
          excerpt: 'Benchmark results for the optimized kernel.',
          reasons: ['Mentions GPU'],
        ),
      ],
    );

    expect(answer, isNotNull);
    expect(answer!.headline, 'I found 2 relevant files');
    expect(answer.body, contains('Kernel profiling notes'));
    expect(answer.body, contains('Benchmark results'));
    expect(answer.evidenceLabels, ['CUDA notes.pdf', 'GPU results.csv']);
    expect(answer.relationships, contains('Mentions CUDA'));
    expect(answer.relationships, contains('Folder: Documents/Research/'));
  });

  test('composer returns no answer when retrieval has no evidence', () {
    expect(KnowledgeAnswerComposer.compose('unknown topic', const []), isNull);
  });

  test('conversation turn and answer survive persistence round-trip', () {
    final original = KnowledgeConversationTurn(
      id: 'turn-1',
      query: 'show related files',
      createdAt: DateTime.utc(2026, 9, 9),
      answer: const KnowledgeAnswer(
        headline: 'I found one relevant file',
        body: 'Notes.pdf: Local evidence.',
        evidenceLabels: ['Notes.pdf'],
        relationships: ['Mentions project'],
      ),
    );

    final restored = KnowledgeConversationTurn.fromJson(original.toJson());
    expect(restored.id, original.id);
    expect(restored.query, original.query);
    expect(restored.createdAt, original.createdAt);
    expect(restored.answer?.body, original.answer?.body);
    expect(restored.answer?.evidenceLabels, ['Notes.pdf']);
  });
}
