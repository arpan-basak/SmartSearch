import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:smart_search_app/features/chat/application/chat_controller.dart';
import 'package:smart_search_app/features/chat/domain/chat_models.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen(
      {super.key,
      required this.controller,
      required this.onOpen,
      required this.onNew,
      required this.onSettings});
  final ChatController controller;
  final ValueChanged<ChatThread> onOpen;
  final VoidCallback onNew;
  final VoidCallback onSettings;
  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  String _filter = '';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
      if (mounted) await widget.controller.initialize();
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final colors = Theme.of(context).colorScheme;
        final threads = controller.threads
            .where((t) =>
                t.title.toLowerCase().contains(_filter) ||
                t.messages.any((m) => m.text.toLowerCase().contains(_filter)))
            .toList();
        return Scaffold(
          appBar: AppBar(title: const Text('Chats'), actions: [
            IconButton(
                tooltip: 'Gemini settings',
                onPressed: widget.onSettings,
                icon: const Icon(Icons.tune_rounded))
          ]),
          floatingActionButton: FloatingActionButton.extended(
              onPressed: controller.loaded ? widget.onNew : null,
              icon: const Icon(Icons.edit_square),
              label: const Text('New chat')),
          body: Center(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                            padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
                            child: Text('A fresh space for every conversation.',
                                style:
                                    TextStyle(color: colors.onSurfaceVariant))),
                        Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: TextField(
                              onChanged: (text) => setState(
                                  () => _filter = text.trim().toLowerCase()),
                              decoration: InputDecoration(
                                  hintText: 'Search your chats',
                                  prefixIcon: const Icon(Icons.search_rounded),
                                  filled: true,
                                  fillColor: colors.surfaceContainerHighest
                                      .withValues(alpha: .45),
                                  border: OutlineInputBorder(
                                      borderSide: BorderSide.none,
                                      borderRadius: BorderRadius.circular(18))),
                            )),
                        if (controller.loaded && !controller.hasApiKey)
                          Padding(
                              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                              child: Material(
                                  color: colors.primaryContainer
                                      .withValues(alpha: .4),
                                  borderRadius: BorderRadius.circular(18),
                                  child: ListTile(
                                      leading: Icon(Icons.key_rounded,
                                          color: colors.primary),
                                      title: const Text('Connect Gemini'),
                                      subtitle: const Text(
                                          'Add your AI Studio key to start asking.'),
                                      trailing: const Icon(Icons.chevron_right),
                                      onTap: widget.onSettings))),
                        const SizedBox(height: 12),
                        Expanded(
                            child: controller.loadError != null
                                ? Center(
                                    child: Padding(
                                        padding: const EdgeInsets.all(24),
                                        child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(controller.loadError!,
                                                  textAlign: TextAlign.center),
                                              const SizedBox(height: 12),
                                              OutlinedButton(
                                                  onPressed:
                                                      controller.retryLoad,
                                                  child: const Text(
                                                      'Retry loading chats'))
                                            ])))
                                : !controller.loaded
                                    ? const Center(
                                        child: CircularProgressIndicator())
                                    : threads.isEmpty
                                        ? Center(
                                            child: Padding(
                                                padding:
                                                    const EdgeInsets.all(32),
                                                child: Column(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Icon(Icons.forum_outlined,
                                                          size: 52,
                                                          color:
                                                              colors.primary),
                                                      const SizedBox(
                                                          height: 18),
                                                      Text(
                                                          _filter.isEmpty
                                                              ? 'Your ideas start here'
                                                              : 'No matching chats',
                                                          style:
                                                              Theme.of(context)
                                                                  .textTheme
                                                                  .titleLarge),
                                                      const SizedBox(height: 8),
                                                      Text(
                                                          _filter.isEmpty
                                                              ? 'Tap New chat to begin. Each conversation has its own history and stays separate.'
                                                              : 'Try another title or message.',
                                                          textAlign:
                                                              TextAlign.center,
                                                          style: TextStyle(
                                                              color: colors
                                                                  .onSurfaceVariant,
                                                              height: 1.5)),
                                                    ])))
                                        : ListView.separated(
                                            padding: const EdgeInsets.only(
                                                bottom: 100),
                                            itemCount: threads.length,
                                            separatorBuilder: (_, __) =>
                                                const Divider(
                                                    indent: 86,
                                                    endIndent: 20,
                                                    height: 1),
                                            itemBuilder: (context, index) {
                                              final thread = threads[index];
                                              final busy =
                                                  controller.isBusy(thread.id);
                                              final last =
                                                  thread.messages.isEmpty
                                                      ? null
                                                      : thread.messages.last;
                                              final preview = busy
                                                  ? 'Gemini is replying…'
                                                  : last == null
                                                      ? 'Start a conversation'
                                                      : last.text.isEmpty
                                                          ? (last.notice ??
                                                              'No answer yet')
                                                          : last.text
                                                              .replaceAll(
                                                                  RegExp(
                                                                      r'\s+'),
                                                                  ' ');
                                              return ListTile(
                                                contentPadding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 20,
                                                        vertical: 9),
                                                leading: CircleAvatar(
                                                    radius: 25,
                                                    backgroundColor: colors
                                                        .primaryContainer
                                                        .withValues(alpha: .6),
                                                    child: Icon(
                                                        Icons
                                                            .chat_bubble_outline_rounded,
                                                        color: colors.primary)),
                                                title: Text(thread.title,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w600)),
                                                subtitle: Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                            top: 5),
                                                    child: Text(preview,
                                                        maxLines: 2,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                            color: busy
                                                                ? colors.primary
                                                                : colors
                                                                    .onSurfaceVariant))),
                                                trailing: Text(
                                                    _date(thread.updatedAt),
                                                    style: TextStyle(
                                                        fontSize: 11,
                                                        color: colors
                                                            .onSurfaceVariant)),
                                                onTap: () =>
                                                    widget.onOpen(thread),
                                                onLongPress: () =>
                                                    showChatActions(context,
                                                        controller, thread),
                                              );
                                            })),
                      ]))),
        );
      });

  String _date(DateTime value) {
    final now = DateTime.now();
    return DateFormat(value.year == now.year &&
                value.month == now.month &&
                value.day == now.day
            ? 'HH:mm'
            : 'd MMM')
        .format(value.toLocal());
  }
}

Future<bool> showChatActions(
    BuildContext context, ChatController controller, ChatThread thread) async {
  final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
                title: Text(thread.title, maxLines: 2),
                subtitle: const Text('This conversation only')),
            ListTile(
                enabled: !controller.isBusy(thread.id),
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Rename chat'),
                onTap: () => Navigator.pop(context, 'rename')),
            ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete chat'),
                onTap: () => Navigator.pop(context, 'delete')),
          ])));
  if (!context.mounted || action == null) return false;
  if (action == 'rename') {
    final name = TextEditingController(text: thread.title);
    final title = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Rename chat'),
              content: TextField(
                  controller: name,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Chat title')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, name.text),
                    child: const Text('Save'))
              ],
            ));
    // The closing dialog still uses its controller during the exit animation.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    name.dispose();
    if (title == null) return false;
    try {
      await controller.rename(thread.id, title);
    } catch (_) {
      if (context.mounted) _error(context);
    }
    return false;
  }
  final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
            title: const Text('Delete this chat?'),
            content: const Text(
                'This removes this conversation and its saved messages from this device. It cannot be undone.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel')),
              TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Delete'))
            ],
          ));
  if (confirm != true) return false;
  try {
    await controller.delete(thread.id);
    return true;
  } catch (_) {
    if (context.mounted) _error(context);
    return false;
  }
}

void _error(BuildContext context) =>
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not update this chat. Please try again.')));
