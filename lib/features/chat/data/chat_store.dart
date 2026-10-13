import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_search_app/core/storage/preference_keys.dart';
import 'package:smart_search_app/features/chat/domain/chat_models.dart';
import 'package:smart_search_app/features/knowledge/domain/knowledge_answer.dart';

abstract interface class ChatStore {
  Future<List<ChatThread>> load();
  Future<void> save(ChatThread thread);
  Future<void> delete(String id);
}

/// App-private, per-conversation files. No I/O occurs during construction.
/// Serialized, flushed replacements keep a recoverable previous revision.
class FileChatStore implements ChatStore {
  FileChatStore({Future<Directory> Function()? directory})
      : _directory = directory ??
            (() async => Directory(
                '${(await getApplicationSupportDirectory()).path}/ai_chats'));

  final Future<Directory> Function() _directory;
  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<File> _file(String id) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      throw ArgumentError('Invalid chat ID');
    }
    final directory = await _directory();
    await directory.create(recursive: true);
    return File('${directory.path}/$id.json');
  }

  @override
  Future<List<ChatThread>> load() => _serial(() async {
        final directory = await _directory();
        await directory.create(recursive: true);
        final ids = <String>{};
        await for (final entry in directory.list()) {
          final name = entry.uri.pathSegments.last;
          final match =
              RegExp(r'^([a-zA-Z0-9_-]+)\.json(?:\.bak)?$').firstMatch(name);
          if (entry is File && match != null) ids.add(match.group(1)!);
        }
        final threads = <ChatThread>[];
        for (final id in ids) {
          final file = await _file(id);
          ChatThread? thread;
          for (final candidate in [file, File('${file.path}.bak')]) {
            if (!await candidate.exists()) continue;
            try {
              final parsed = ChatThread.fromJson(
                  jsonDecode(await candidate.readAsString())
                      as Map<String, dynamic>);
              if (parsed.id != id) {
                throw const FormatException('Mismatched chat ID');
              }
              thread = parsed;
              // Restore a good backup before accepting any subsequent writes.
              if (candidate.path != file.path) {
                if (await file.exists()) {
                  await file.rename('${file.path}.corrupt');
                }
                await candidate.copy(file.path);
              }
              break;
            } on FormatException {
              continue;
            } on TypeError {
              continue;
            } on ArgumentError {
              continue;
            }
          }
          if (thread == null) {
            throw const FormatException(
                'Chat history needs recovery; original files have been preserved.');
          }
          threads.add(thread);
        }
        return threads;
      });

  @override
  Future<void> save(ChatThread thread) {
    final encoded = jsonEncode(thread.toJson());
    return _serial(() async {
      final file = await _file(thread.id);
      final pending = File('${file.path}.tmp');
      final backup = File('${file.path}.bak');
      await pending.writeAsString(encoded, flush: true);
      if (await file.exists()) {
        if (await backup.exists()) await backup.delete();
        await file.rename(backup.path);
      }
      await pending.rename(file.path);
    });
  }

  @override
  Future<void> delete(String id) => _serial(() async {
        final file = await _file(id);
        // Backups go first so an interrupted deletion cannot resurrect the chat.
        for (final suffix in ['.bak', '.tmp', '.corrupt', '']) {
          final target = File('${file.path}$suffix');
          if (await target.exists()) await target.delete();
        }
      });
}

/// Archive the old single conversation once. Never discard its source data.
Future<void> migrateLegacyChat(
    ChatStore store, List<ChatThread> threads) async {
  final prefs = await SharedPreferences.getInstance();
  const migrationKey = 'gemini_legacy_chat_migrated_v1';
  if (prefs.getBool(migrationKey) == true) return;
  const id = 'legacy-conversation';
  final raw = prefs.getString(PreferenceKeys.localConversation);
  if (raw != null && !threads.any((t) => t.id == id)) {
    final turns = (jsonDecode(raw) as List)
        .map((item) => KnowledgeConversationTurn.fromJson(
            Map<String, dynamic>.from(item as Map)))
        .toList();
    final messages = <ChatMessage>[];
    for (final turn in turns) {
      messages.add(ChatMessage(
          id: '${turn.id}-user',
          role: ChatRole.user,
          text: turn.query,
          createdAt: turn.createdAt));
      if (turn.answer case final answer?) {
        messages.add(ChatMessage(
            id: '${turn.id}-answer',
            role: ChatRole.assistant,
            text: '${answer.headline}\n\n${answer.body}',
            createdAt: turn.createdAt,
            model: 'On-device answer'));
      }
    }
    if (messages.isNotEmpty) {
      final thread = ChatThread(
          id: id,
          title: 'Previous conversation',
          createdAt: messages.first.createdAt,
          updatedAt: messages.last.createdAt,
          messages: messages);
      await store.save(thread);
      threads.add(thread);
    }
  }
  await prefs.setBool(migrationKey, true);
}
