import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:smart_search_app/features/documents/domain/document_search_worker.dart';

/// Starts on the first settled query, never during application startup.
class DocumentSearchService {
  final _pending = <int, Completer<List<Map<String, dynamic>>>>{};
  Isolate? _isolate;
  ReceivePort? _replies;
  Future<SendPort>? _connection;
  Completer<SendPort>? _starting;
  int _nextId = 0;
  bool _disposed = false;

  Future<SendPort> _start() async {
    final ready = Completer<SendPort>();
    _starting = ready;
    // Install an error listener immediately, including disposal during spawn.
    unawaited(ready.future.then<void>((_) {}, onError: (Object _) {}));
    final replies = ReceivePort();
    _replies = replies;
    replies.listen((dynamic message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
      } else if (message is List && message.length == 3) {
        final completer = _pending.remove(message[0]);
        if (message[2] != null) {
          completer?.completeError(StateError('${message[2]}'));
        } else {
          completer
              ?.complete((message[1] as List).cast<Map<String, dynamic>>());
        }
      } else {
        final error = StateError('Document search worker stopped');
        if (!ready.isCompleted) ready.completeError(error);
        for (final pending in _pending.values) {
          pending.completeError(error);
        }
        _pending.clear();
        _connection = null;
        replies.close();
      }
    });
    try {
      _isolate = await Isolate.spawn(_documentSearchEntry, replies.sendPort,
          onError: replies.sendPort, onExit: replies.sendPort);
      if (_disposed) {
        _isolate?.kill(priority: Isolate.immediate);
        throw StateError('Document search disposed');
      }
      return await ready.future;
    } catch (_) {
      replies.close();
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> rank(Map<String, dynamic> request) async {
    if (_disposed) throw StateError('Document search disposed');
    // Flutter web has no Dart isolates; keep its existing supported fallback.
    if (kIsWeb) return compute(rankDocumentBatch, request);
    final port = await (_connection ??= _start());
    if (_disposed) throw StateError('Document search disposed');
    final id = _nextId++;
    final result = Completer<List<Map<String, dynamic>>>();
    _pending[id] = result;
    port.send([id, request]);
    return result.future;
  }

  void dispose() {
    _disposed = true;
    if (_starting != null && !_starting!.isCompleted) {
      _starting!.completeError(StateError('Document search disposed'));
    }
    _isolate?.kill(priority: Isolate.immediate);
    _replies?.close();
    for (final pending in _pending.values) {
      pending.completeError(StateError('Document search disposed'));
    }
    _pending.clear();
  }
}

void _documentSearchEntry(SendPort replies) {
  final requests = ReceivePort();
  final ranker = DocumentRanker();
  replies.send(requests.sendPort);
  requests.listen((dynamic message) {
    final id = message[0] as int;
    try {
      replies.send([id, ranker.rank(message[1] as Map<String, dynamic>), null]);
    } catch (error) {
      replies.send([id, null, error.toString()]);
    }
  });
}
