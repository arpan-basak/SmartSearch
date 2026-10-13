import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:intl/intl.dart';
import 'package:smart_search_app/core/platform/search_platform.dart';
import 'package:smart_search_app/features/chat/application/chat_controller.dart';
import 'package:smart_search_app/features/chat/data/gemini_client.dart';
import 'package:smart_search_app/features/chat/domain/chat_models.dart';
import 'package:smart_search_app/features/chat/presentation/chat_list_screen.dart';
import 'package:url_launcher/url_launcher.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen(
      {super.key,
      required this.controller,
      required this.threadId,
      required this.onSettings,
      this.initialDraft = ''});
  final ChatController controller;
  final String threadId;
  final VoidCallback onSettings;
  final String initialDraft;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final TextEditingController _text;
  final _scroll = ScrollController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(
        text: widget.initialDraft.isNotEmpty
            ? widget.initialDraft
            : widget.controller.draft(widget.threadId));
    _text.addListener(_onDraft);
    widget.controller.addListener(_onUpdate);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLatest());
  }

  void _onDraft() => widget.controller.setDraft(widget.threadId, _text.text);
  void _onUpdate() {
    if (!_scroll.hasClients || _scroll.position.extentAfter < 180) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLatest());
    }
  }

  void _scrollToLatest() {
    if (mounted && _scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  }

  Future<void> _send({bool retry = false}) async {
    if (_sending || widget.controller.isBusy(widget.threadId)) return;
    final text = _text.text.trim();
    if (!retry && text.isEmpty) return;
    setState(() => _sending = true);
    if (!retry) _text.clear();
    try {
      await widget.controller.send(widget.threadId, text, retry: retry);
    } catch (error) {
      if (mounted) {
        if (!retry && _text.text.isEmpty) _text.text = text;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(error is GeminiException
                ? error.message
                : 'Could not send this message. Please try again.')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onUpdate);
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final thread = controller.thread(widget.threadId);
        final colors = Theme.of(context).colorScheme;
        if (thread == null) {
          return Scaffold(
              appBar: AppBar(title: const Text('Chat')),
              body: const Center(child: Text('This chat has been deleted.')));
        }
        final busy = controller.isBusy(thread.id);
        return Scaffold(
          appBar: AppBar(
              title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(thread.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w600)),
                    Text(
                        controller.isRetrieving(thread.id)
                            ? 'Searching indexed documents…'
                            : busy
                                ? 'Gemini is replying…'
                                : 'Gemini • Saved on this device',
                        style: TextStyle(
                            fontSize: 11, color: colors.onSurfaceVariant)),
                  ]),
              actions: [
                IconButton(
                    tooltip: 'Chat options',
                    icon: const Icon(Icons.more_vert),
                    onPressed: () async {
                      final deleted =
                          await showChatActions(context, controller, thread);
                      if (deleted && context.mounted) Navigator.pop(context);
                    })
              ]),
          body: SafeArea(
              top: false,
              child: Center(
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 800),
                      child: Column(children: [
                        SwitchListTile.adaptive(
                          dense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 16),
                          title: const Text('Use indexed documents'),
                          subtitle: const Text(
                              'Send matching excerpts to Gemini with your question.'),
                          value: thread.useIndexedContext,
                          onChanged: busy
                              ? null
                              : (enabled) async {
                                  try {
                                    await controller.setIndexedContext(
                                        thread.id, enabled);
                                  } catch (_) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(const SnackBar(
                                              content: Text(
                                                  'Could not save the context setting. Please try again.')));
                                    }
                                  }
                                },
                        ),
                        if (!controller.hasApiKey)
                          Material(
                              color:
                                  colors.primaryContainer.withValues(alpha: .4),
                              child: ListTile(
                                  leading: const Icon(Icons.key_rounded),
                                  title: const Text('Add your Gemini API key'),
                                  subtitle: const Text(
                                      'Your saved chats are still available.'),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: widget.onSettings)),
                        if (controller.storageError != null)
                          MaterialBanner(
                              content: Text(controller.storageError!),
                              actions: [
                                TextButton(
                                    onPressed: () =>
                                        controller.retrySave(thread.id),
                                    child: const Text('Retry save'))
                              ]),
                        if (thread.id == 'legacy-conversation')
                          const Padding(
                              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                              child: Text(
                                  'Archived on-device answers are shown here, but are not sent to Gemini.',
                                  style: TextStyle(fontSize: 11))),
                        Expanded(
                            child: thread.messages.isEmpty
                                ? _empty(colors)
                                : ListView.builder(
                                    controller: _scroll,
                                    padding: const EdgeInsets.fromLTRB(
                                        16, 18, 16, 20),
                                    itemCount: thread.messages.length,
                                    itemBuilder: (context, index) {
                                      final message = thread.messages[index];
                                      final showDate = index == 0 ||
                                          !_sameDay(
                                              thread.messages[index - 1]
                                                  .createdAt,
                                              message.createdAt);
                                      return Column(children: [
                                        if (showDate)
                                          Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      vertical: 14),
                                              child: Text(
                                                  DateFormat('d MMM yyyy')
                                                      .format(message.createdAt
                                                          .toLocal()),
                                                  style: TextStyle(
                                                      fontSize: 11,
                                                      color: colors
                                                          .onSurfaceVariant))),
                                        _MessageBubble(
                                            message: message,
                                            canRetry: !busy &&
                                                index ==
                                                    thread.messages.length - 1,
                                            onRetry: () => _send(retry: true)),
                                      ]);
                                    })),
                        Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                                'AI can make mistakes. Check the supplied sources. No live web search.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 10,
                                    color: colors.onSurfaceVariant))),
                        Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                            child: Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Expanded(
                                      child: TextField(
                                          key: const Key('chat-composer'),
                                          controller: _text,
                                          minLines: 1,
                                          maxLines: 5,
                                          maxLength: 32000,
                                          textCapitalization:
                                              TextCapitalization.sentences,
                                          keyboardType: TextInputType.multiline,
                                          decoration: InputDecoration(
                                              hintText: 'Message Gemini',
                                              counterText: '',
                                              filled: true,
                                              fillColor: colors
                                                  .surfaceContainerHighest
                                                  .withValues(alpha: .45),
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 18,
                                                      vertical: 14),
                                              border: OutlineInputBorder(
                                                  borderSide: BorderSide.none,
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          26))))),
                                  const SizedBox(width: 8),
                                  IconButton.filled(
                                      tooltip:
                                          busy ? 'Stop reply' : 'Send message',
                                      onPressed: busy
                                          ? () => controller.stop(thread.id)
                                          : !controller.hasApiKey || _sending
                                              ? null
                                              : () => _send(),
                                      icon: Icon(busy
                                          ? Icons.stop_rounded
                                          : Icons.arrow_upward_rounded),
                                      constraints: const BoxConstraints(
                                          minWidth: 48, minHeight: 48)),
                                ])),
                      ])))),
        );
      });

  Widget _empty(ColorScheme colors) => SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(children: [
        const SizedBox(height: 44),
        CircleAvatar(
            radius: 32,
            backgroundColor: colors.primaryContainer.withValues(alpha: .5),
            child: Icon(Icons.auto_awesome, color: colors.primary, size: 30)),
        const SizedBox(height: 22),
        Text('What’s on your mind?',
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center),
        const SizedBox(height: 10),
        Text(
            'Ask about your indexed documents or a general topic. Follow-ups use this chat’s messages; matching file excerpts are included when enabled.',
            style: TextStyle(color: colors.onSurfaceVariant, height: 1.5),
            textAlign: TextAlign.center),
        const SizedBox(height: 24),
        for (final prompt in [
          'Explain lossless data compression with examples',
          'Help me make a study plan',
          'Compare two ideas step by step'
        ])
          Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: OutlinedButton(
                  onPressed: () => _text.text = prompt,
                  child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(prompt, textAlign: TextAlign.center)))),
      ]));

  bool _sameDay(DateTime a, DateTime b) =>
      a.toLocal().year == b.toLocal().year &&
      a.toLocal().month == b.toLocal().month &&
      a.toLocal().day == b.toLocal().day;
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble(
      {required this.message, required this.canRetry, required this.onRetry});
  final ChatMessage message;
  final bool canRetry;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final user = message.role == ChatRole.user;
    final colors = Theme.of(context).colorScheme;
    return Align(
        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 650),
          margin: EdgeInsets.only(
              left: user ? 36 : 0, right: user ? 0 : 20, bottom: 16),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          decoration: BoxDecoration(
              color: user
                  ? colors.primaryContainer
                  : colors.surfaceContainerHighest.withValues(alpha: .45),
              borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(20),
                  topRight: const Radius.circular(20),
                  bottomLeft: Radius.circular(user ? 20 : 4),
                  bottomRight: Radius.circular(user ? 4 : 20))),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!user)
                  Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                          message.model == 'On-device answer'
                              ? 'ON-DEVICE ARCHIVE'
                              : 'GEMINI',
                          style: TextStyle(
                              fontSize: 10,
                              letterSpacing: 1.4,
                              color: colors.primary,
                              fontWeight: FontWeight.w700))),
                if (message.text.isNotEmpty)
                  user
                      ? SelectableText(message.text,
                          style: TextStyle(
                              color: colors.onPrimaryContainer, height: 1.5))
                      : MarkdownBody(
                          data: message.text,
                          selectable: true,
                          // Model output must not trigger network requests or local file reads.
                          imageBuilder: (uri, title, alt) =>
                              Text('[Image: ${alt ?? 'not loaded'}]'),
                          onTapLink: (_, href, __) => _openLink(context, href),
                          styleSheet:
                              MarkdownStyleSheet.fromTheme(Theme.of(context))
                                  .copyWith(
                                      p: TextStyle(
                                          color: colors.onSurface,
                                          height: 1.5))),
                if (message.status == MessageStatus.streaming &&
                    message.text.isEmpty)
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 10),
                        Text('Thinking…')
                      ])),
                if (message.notice != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(message.notice!,
                          style: TextStyle(
                              color: colors.error, height: 1.4, fontSize: 12))),
                if (!user && message.documentContext != null)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(message.documentContext!.description,
                        style: const TextStyle(fontSize: 12)),
                    children: message.documentContext!.sources
                        .map((source) => Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('[${source.id}] ${source.title}',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600)),
                                    const SizedBox(height: 4),
                                    SelectableText(source.excerpt,
                                        style: const TextStyle(fontSize: 12)),
                                    TextButton.icon(
                                      onPressed: () async {
                                        try {
                                          final opened =
                                              await searchPlatformChannel
                                                  .invokeMethod<bool>(
                                                      'openDocument', {
                                            'path': source.path,
                                            'name': source.title
                                          });
                                          if (opened == false) {
                                            throw StateError('Unavailable');
                                          }
                                        } catch (_) {
                                          if (context.mounted) {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(const SnackBar(
                                                    content: Text(
                                                        'Could not open this source. It may have moved or access may have changed.')));
                                          }
                                        }
                                      },
                                      icon: const Icon(Icons.open_in_new,
                                          size: 16),
                                      label: const Text('Open source'),
                                    ),
                                  ]),
                            ))
                        .toList(),
                  ),
                if (!user &&
                    (message.status == MessageStatus.failed ||
                        message.status == MessageStatus.interrupted)) ...[
                  const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                          'This incomplete exchange is not used in later answers.',
                          style: TextStyle(fontSize: 10))),
                  if (canRetry)
                    TextButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Retry answer')),
                ],
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(DateFormat('HH:mm').format(message.createdAt.toLocal()),
                      style: TextStyle(
                          color: user
                              ? colors.onPrimaryContainer.withValues(alpha: .7)
                              : colors.onSurfaceVariant,
                          fontSize: 10)),
                  if (message.text.isNotEmpty)
                    IconButton(
                        tooltip: 'Copy message',
                        visualDensity: VisualDensity.compact,
                        iconSize: 14,
                        onPressed: () => Clipboard.setData(
                            ClipboardData(text: message.text)),
                        icon: const Icon(Icons.copy_outlined)),
                ]),
              ]),
        ));
  }

  Future<void> _openLink(BuildContext context, String? href) async {
    final uri = Uri.tryParse(href ?? '');
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      return;
    }
    final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Open this link?'),
                content: Text(uri.toString()),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Open browser'))
                ]));
    if (approved != true) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {/* The original answer remains readable. */}
  }
}
