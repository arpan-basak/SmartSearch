import 'dart:convert';
import 'dart:io';

import 'package:smart_search_app/features/documents/domain/document_search_worker.dart';

void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln(
        'Usage: dart run tool/retrieval_benchmark.dart <benchmark.json>');
    exitCode = 64;
    return;
  }
  final source = File(arguments.single);
  final fixture = jsonDecode(source.readAsStringSync()) as Map<String, dynamic>;
  final documents = (fixture['documents'] as List)
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList();
  final queries = (fixture['queries'] as List)
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList();
  if (queries.isEmpty) {
    throw FormatException('Benchmark must contain at least one labeled query.');
  }

  final ranker = DocumentRanker();
  final hits = <int, int>{1: 0, 3: 0, 5: 0};
  final durations = <int>[];
  for (final example in queries) {
    final relevant = (example['relevantPaths'] as List).cast<String>().toSet();
    final watch = Stopwatch()..start();
    final ranked = ranker.rank({
      'query': example['query'] as String,
      'documents': documents,
    });
    watch.stop();
    durations.add(watch.elapsedMicroseconds);
    for (final k in hits.keys) {
      if (ranked.take(k).any((row) => relevant.contains(row['path']))) {
        hits[k] = hits[k]! + 1;
      }
    }
  }
  durations.sort();
  int percentile(double value) =>
      durations[((durations.length - 1) * value).round()];
  stdout.writeln('Queries: ${queries.length}');
  for (final k in hits.keys) {
    stdout.writeln(
        'Recall@$k: ${(hits[k]! / queries.length * 100).toStringAsFixed(1)}%');
  }
  stdout.writeln(
      'Latency p50: ${(percentile(.50) / 1000).toStringAsFixed(2)} ms');
  stdout.writeln(
      'Latency p95: ${(percentile(.95) / 1000).toStringAsFixed(2)} ms');
}
