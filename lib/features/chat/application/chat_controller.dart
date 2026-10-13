import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:smart_search_app/features/chat/data/chat_context_repository.dart';
import 'package:smart_search_app/features/chat/data/chat_store.dart';
import 'package:smart_search_app/features/chat/data/gemini_client.dart';
import 'package:smart_search_app/features/chat/data/gemini_settings_store.dart';
import 'package:smart_search_app/features/chat/domain/chat_document_context.dart';
import 'package:smart_search_app/features/chat/domain/chat_models.dart';

class ChatController extends ChangeNotifier {
  ChatController(
      {required this.store,
      required this.settingsStore,
      required this.gateway,
      this.contextRepository,
      this.migrateLegacy = true});
  factory ChatController.device() => ChatController(
      store: FileChatStore(),
      settingsStore: const SecureGeminiSettingsStore(),
      gateway: GeminiClient(),
      contextRepository: const NativeChatContextRepository());
  final ChatStore store;
  final GeminiSettingsStore settingsStore;
  final GeminiGateway gateway;
  final ChatContextRepository? contextRepository;
  final bool migrateLegacy;
  final Map<String, ChatThread> _threads = {};
  final Map<String, GeminiCancellation> _requests = {};
  final Set<String> _mutating = {};
  final Map<String, String> _drafts = {};
  final Set<String> _retrieving = {};
  Future<void>? _initialization;
  bool _disposed = false;
  bool loaded = false;
  bool hasApiKey = false;
  String? loadError;
  String? storageError;

  List<ChatThread> get threads => _threads.values.toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  ChatThread? thread(String id) => _threads[id];
  bool isBusy(String id) => _requests.containsKey(id) || _mutating.contains(id);
  bool isRetrieving(String id) => _retrieving.contains(id);
  String draft(String id) => _drafts[id] ?? '';
  void setDraft(String id, String text) => _drafts[id] = text;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initialization ??= _load();
  Future<void> _load() async {
    loadError = null;
    try {
      final saved = await store.load();
      if (migrateLegacy) await migrateLegacyChat(store, saved);
      for (final thread in saved) {
        final recovered = thread.copyWith(
            messages: thread.messages
                .map((m) => m.status == MessageStatus.streaming
                    ? m.copyWith(
                        status: MessageStatus.interrupted,
                        notice:
                            'Reply interrupted when the app closed. You can retry.')
                    : m)
                .toList());
        _threads[thread.id] = recovered;
      }
      loaded = true;
    } catch (_) {
      loadError =
          'Could not load chat history. Existing files were kept safe. Try again; do not clear app data.';
    }
    await refreshConfiguration();
    _notify();
  }

  Future<void> retryLoad() {
    _initialization = null;
    return initialize();
  }

  Future<void> refreshConfiguration() async {
    try {
      hasApiKey = (await settingsStore.read()).configured;
    } catch (_) {
      hasApiKey = false;
    }
    _notify();
  }

  Future<ChatThread> create() async {
    await initialize();
    if (!loaded) throw StateError('Chat history is not available yet.');
    final now = DateTime.now();
    final thread = ChatThread(
        id: newChatId(), title: 'New chat', createdAt: now, updatedAt: now);
    await store.save(thread);
    _threads[thread.id] = thread;
    _notify();
    return thread;
  }

  Future<void> rename(String id, String title) async {
    if (isBusy(id)) return;
    final thread = _threads[id];
    if (thread == null || title.trim().isEmpty) return;
    _mutating.add(id);
    _notify();
    try {
      final renamed = thread.copyWith(title: title.trim());
      await store.save(renamed);
      _threads[id] = renamed;
    } finally {
      _mutating.remove(id);
      _notify();
    }
  }

  Future<void> delete(String id) async {
    if (_mutating.contains(id)) return;
    _mutating.add(id);
    // Remove its request identity before cancellation. Late callbacks can no
    // longer write to or resurrect this conversation, even after navigation.
    _requests.remove(id)?.cancel();
    _notify();
    try {
      await store.delete(id);
      _threads.remove(id);
      _drafts.remove(id);
    } finally {
      _mutating.remove(id);
      _notify();
    }
  }

  void stop(String id) => _requests[id]?.cancel();

  Future<void> setIndexedContext(String id, bool enabled) async {
    final value = _threads[id];
    if (value == null || isBusy(id)) return;
    _mutating.add(id);
    _notify();
    try {
      final updated = value.copyWith(useIndexedContext: enabled);
      await store.save(updated);
      _threads[id] = updated;
    } finally {
      _mutating.remove(id);
      _notify();
    }
  }

  Future<void> send(String id, String text, {bool retry = false}) async {
    final original = _threads[id];
    final prompt = text.trim();
    if (original == null || isBusy(id)) return;
    if (!retry && (prompt.isEmpty || prompt.length > 32000)) {
      throw const GeminiException(
          'Enter a message of up to 32,000 characters.');
    }
    final cancellation = GeminiCancellation();
    _requests[id] = cancellation;
    _notify();
    bool current() =>
        !_disposed &&
        identical(_requests[id], cancellation) &&
        _threads.containsKey(id);
    String? replyId;
    try {
      final settings = await settingsStore.read();
      if (!current()) return;
      if (!settings.configured) {
        throw const GeminiException(
            'Add your Gemini API key in Settings first.');
      }
      var messages = original.messages.toList();
      if (retry) {
        if (messages.length < 2 ||
            messages.last.role != ChatRole.assistant ||
            messages.last.status == MessageStatus.complete) {
          return;
        }
        messages.removeLast();
      } else {
        messages.add(ChatMessage(
            id: newChatId(),
            role: ChatRole.user,
            text: prompt,
            createdAt: DateTime.now()));
      }
      // Include complete exchanges only, never failed/partial model answers.
      // Every exchange is from this thread; nothing comes from another chat.
      final context = <ChatMessage>[];
      for (var i = 0; i < messages.length - 1; i++) {
        if (messages[i].role == ChatRole.user &&
            messages[i + 1].role == ChatRole.assistant &&
            messages[i + 1].model != 'On-device answer' &&
            messages[i + 1].status == MessageStatus.complete) {
          context.addAll([messages[i], messages[i + 1]]);
          i++;
        }
      }
      context.add(messages.last);
      replyId = newChatId();
      final answer = ChatMessage(
          id: replyId,
          role: ChatRole.assistant,
          text: '',
          createdAt: DateTime.now(),
          status: MessageStatus.streaming,
          model: settings.model);
      messages.add(answer);
      final title = original.messages.isEmpty && original.title == 'New chat'
          ? String.fromCharCodes(
              prompt.replaceAll(RegExp(r'\s+'), ' ').runes.take(60))
          : original.title;
      final updated = original.copyWith(
          title: title, messages: messages, updatedAt: DateTime.now());
      // Do not send to Google if saving the user's message failed.
      await store.save(updated);
      if (!current()) return;
      _threads[id] = updated;
      _drafts.remove(id);
      storageError = null;
      _notify();
      ChatDocumentContext? documentContext;
      if (original.useIndexedContext &&
          contextRepository != null &&
          !cancellation.cancelled) {
        _retrieving.add(id);
        _notify();
        try {
          documentContext = await Future.any([
            contextRepository!
                .search(
                    context.last.text,
                    context
                        .take(context.length - 1)
                        .where((m) => m.role == ChatRole.user)
                        .map((m) => m.text)
                        .toList())
                .timeout(const Duration(seconds: 12)),
            cancellation.whenCancelled.then((_) =>
                const ChatDocumentContext(DocumentContextStatus.unavailable)),
          ]);
        } catch (_) {
          documentContext =
              const ChatDocumentContext(DocumentContextStatus.unavailable);
        } finally {
          _retrieving.remove(id);
          _notify();
        }
        if (!current()) return;
        if (!cancellation.cancelled) {
          _replaceAnswer(
              id,
              _threads[id]!
                  .messages
                  .last
                  .copyWith(documentContext: documentContext));
          // Save the exact evidence before sending it, so citations remain
          // reviewable after reopening or a failed/partial provider response.
          await store.save(_threads[id]!);
          if (!current()) return;
        }
      }
      var lastCheckpoint = DateTime.now();
      if (!cancellation.cancelled) {
        await for (final chunk in gateway.reply(
            settings: settings,
            messages: context,
            documentContext: documentContext,
            cancellation: cancellation)) {
          if (!current()) return;
          if (cancellation.cancelled) break;
          final currentAnswer = _threads[id]!.messages.last;
          _replaceAnswer(
              id, currentAnswer.copyWith(text: currentAnswer.text + chunk));
          if (DateTime.now().difference(lastCheckpoint) >
              const Duration(seconds: 1)) {
            await _persist(id);
            lastCheckpoint = DateTime.now();
          }
        }
      }
      if (current()) {
        final last = _threads[id]!.messages.last;
        _replaceAnswer(
            id,
            last.copyWith(
                status: cancellation.cancelled
                    ? MessageStatus.interrupted
                    : MessageStatus.complete,
                notice: cancellation.cancelled
                    ? 'Reply stopped. You can retry.'
                    : null));
      }
    } catch (error) {
      if (!current()) return;
      final messages = _threads[id]!.messages;
      if (replyId == null || messages.isEmpty || messages.last.id != replyId) {
        if (error is GeminiException) rethrow;
        throw const GeminiException(
            'Could not read secure settings or save your message. No request was sent. Please try again.');
      }
      final failure = error is GeminiException
          ? error
          : const GeminiException(
              'The reply was interrupted. Please try again.');
      _replaceAnswer(
          id,
          messages.last.copyWith(
            text: failure.discardPartial ? '' : messages.last.text,
            status: cancellation.cancelled
                ? MessageStatus.interrupted
                : MessageStatus.failed,
            notice: cancellation.cancelled
                ? 'Reply stopped. You can retry.'
                : failure.message,
          ));
    } finally {
      if (current()) {
        await _persist(id);
        if (current()) _requests.remove(id);
        _notify();
      }
    }
  }

  void _replaceAnswer(String id, ChatMessage answer) {
    final thread = _threads[id]!;
    _threads[id] = thread.copyWith(
        messages: [...thread.messages.take(thread.messages.length - 1), answer],
        updatedAt: DateTime.now());
    _notify();
  }

  Future<void> _persist(String id) async {
    final value = _threads[id];
    if (value == null) return;
    try {
      await store.save(value);
      storageError = null;
    } catch (_) {
      storageError =
          'Latest changes could not be saved. Keep the app open, free device space, then retry saving.';
    }
    _notify();
  }

  Future<void> retrySave(String id) => _persist(id);

  @override
  void dispose() {
    _disposed = true;
    for (final request in _requests.values) {
      request.cancel();
    }
    super.dispose();
  }
}
