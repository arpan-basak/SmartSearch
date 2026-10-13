import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:smart_search_app/core/platform/search_platform.dart';
import 'package:smart_search_app/design_system/nexa_theme.dart';
import 'package:smart_search_app/features/search/models/search_result.dart';
import 'package:smart_search_app/features/search/presentation/widgets/search_result_artwork.dart';

class HistoryScreen extends StatefulWidget {
  final List<SearchResult> history;
  final VoidCallback onClearAll;
  final ValueChanged<SearchResult> onItemTap;
  final VoidCallback onBack;

  const HistoryScreen({
    super.key,
    required this.history,
    required this.onClearAll,
    required this.onItemTap,
    required this.onBack,
  });

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _searching = false;
  String _filter = 'All';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<SearchResult> get _visibleHistory {
    final query = _searchController.text.trim().toLowerCase();
    return widget.history.where((item) {
      final matchesQuery = query.isEmpty ||
          item.title.toLowerCase().contains(query) ||
          item.subtitle.toLowerCase().contains(query);
      final matchesFilter = switch (_filter) {
        'Actions' =>
          item.kind == ResultKind.action || item.kind == ResultKind.app,
        'Files' => item.kind == ResultKind.document,
        'Web' => item.kind == ResultKind.web,
        _ => true,
      };
      return matchesQuery && matchesFilter;
    }).toList();
  }

  String _dateLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final distance = today.difference(day).inDays;
    if (distance == 0) return 'Today';
    if (distance == 1) return 'Yesterday';
    if (distance < 7) return 'Previous 7 days';
    return DateFormat('MMMM yyyy').format(date);
  }

  void _showDetail(SearchResult item) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        final timestamp = item.timestamp ?? DateTime.now();
        final kind = switch (item.kind) {
          ResultKind.action => 'Device action',
          ResultKind.app => 'App',
          ResultKind.document => 'File',
          ResultKind.web => 'Web',
        };
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: NexaColors.cyan.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(item.icon, color: NexaColors.cyan),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.title,
                              style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 2),
                          Text(
                            '$kind • ${DateFormat('d MMM, h:mm a').format(timestamp)}',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: NexaColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                const NexaSectionLabel('Details'),
                const SizedBox(height: 10),
                Text(
                  item.subtitle.isEmpty
                      ? 'No additional details'
                      : item.subtitle,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                if (item.path?.isNotEmpty == true) ...[
                  const SizedBox(height: 12),
                  Text(
                    item.path!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: NexaColors.textTertiary,
                        ),
                  ),
                ],
                const SizedBox(height: 22),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: NexaColors.cyan.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lock_outline_rounded,
                          size: 19, color: NexaColors.cyan),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'This history stays on this device unless account sync is explicitly enabled.',
                          style: TextStyle(
                            color: NexaColors.textSecondary,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    widget.onItemTap(item);
                  },
                  icon: const Icon(Icons.replay_rounded),
                  label: const Text('Run again'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleHistory;
    final grouped = <String, List<SearchResult>>{};
    for (final item in visible) {
      final date = item.timestamp ?? DateTime.now();
      grouped.putIfAbsent(_dateLabel(date), () => []).add(item);
    }

    return Scaffold(
      backgroundColor: NexaColors.canvas,
      body: SafeArea(
        child: Center(
            child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            children: [
              NexaPageHeader(
                title: 'History',
                subtitle: 'Conversations, searches and actions',
                onBack: widget.onBack,
                actions: [
                  IconButton(
                    tooltip: _searching ? 'Close search' : 'Search history',
                    onPressed: () => setState(() {
                      _searching = !_searching;
                      if (!_searching) {
                        _searchController.clear();
                      }
                    }),
                    icon: Icon(
                      _searching ? Icons.close_rounded : Icons.search_rounded,
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'History options',
                    onSelected: (value) {
                      if (value == 'clear') widget.onClearAll();
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                          value: 'clear', child: Text('Clear history')),
                    ],
                  ),
                ],
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _searching
                    ? Padding(
                        key: const ValueKey('history-search'),
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                        child: TextField(
                          controller: _searchController,
                          autofocus: true,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            hintText: 'Search your history',
                            prefixIcon: Icon(Icons.search_rounded),
                          ),
                        ),
                      )
                    : const SizedBox(key: ValueKey('history-search-closed')),
              ),
              SizedBox(
                height: 46,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  scrollDirection: Axis.horizontal,
                  itemCount: const ['All', 'Actions', 'Files', 'Web'].length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final filter =
                        const ['All', 'Actions', 'Files', 'Web'][index];
                    return ChoiceChip(
                      selected: _filter == filter,
                      label: Text(filter),
                      onSelected: (_) => setState(() => _filter = filter),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: visible.isEmpty
                    ? _HistoryEmptyState(
                        filtered: widget.history.isNotEmpty,
                        onStart: widget.onBack,
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                        itemCount: grouped.length,
                        itemBuilder: (context, index) {
                          final dateLabel = grouped.keys.elementAt(index);
                          final items = grouped[dateLabel]!;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(2, 18, 2, 8),
                                child: NexaSectionLabel(dateLabel),
                              ),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: NexaColors.raised,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: const Color(0x14FFFFFF),
                                  ),
                                ),
                                child: Column(
                                  children: items
                                      .map(
                                        (item) => _HistoryTile(
                                          item: item,
                                          onTap: () => widget.onItemTap(item),
                                          onReplay: () => _showDetail(item),
                                        ),
                                      )
                                      .toList(),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
        )),
      ),
    );
  }
}

class _HistoryTile extends StatefulWidget {
  final SearchResult item;
  final VoidCallback onTap;
  final VoidCallback onReplay;

  const _HistoryTile({
    required this.item,
    required this.onTap,
    required this.onReplay,
  });

  @override
  State<_HistoryTile> createState() => _HistoryTileState();
}

class _HistoryTileState extends State<_HistoryTile> {
  String? _logo;
  SearchResult get item => widget.item;

  @override
  void initState() {
    super.initState();
    _loadLogo();
  }

  @override
  void didUpdateWidget(_HistoryTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.packageName != item.packageName) {
      _logo = null;
      _loadLogo();
    }
  }

  Future<void> _loadLogo() async {
    final package = item.packageName;
    if (item.kind != ResultKind.app || package == null) return;
    await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
    if (!mounted) return;
    try {
      final logo = await searchPlatformChannel
          .invokeMethod<String>('getAppIcon', {'package': package});
      if (mounted && item.packageName == package) setState(() => _logo = logo);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final badgeColor = switch (item.kind) {
      ResultKind.web => NexaColors.info,
      ResultKind.document => NexaColors.iris,
      ResultKind.app => NexaColors.warning,
      ResultKind.action => NexaColors.success,
    };
    return InkWell(
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(children: [
          SearchResultArtwork(
              result:
                  _logo?.isNotEmpty == true ? item.withPreview(_logo!) : item,
              accent: badgeColor),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 12, color: NexaColors.textSecondary)),
            ],
          )),
          IconButton(
            tooltip: 'View details',
            onPressed: widget.onReplay,
            icon: const Icon(Icons.info_outline_rounded, size: 20),
          ),
        ]),
      ),
    );
  }
}

class _HistoryEmptyState extends StatelessWidget {
  const _HistoryEmptyState({required this.filtered, required this.onStart});

  final bool filtered;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                color: NexaColors.cyan.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.history_toggle_off_rounded,
                color: NexaColors.cyan,
                size: 30,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              filtered ? 'No matching history' : 'No history yet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              filtered
                  ? 'Try another search or choose a different filter.'
                  : 'Your conversations and completed actions will appear here.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: NexaColors.textSecondary,
                  ),
            ),
            if (!filtered) ...[
              const SizedBox(height: 18),
              TextButton(
                  onPressed: onStart,
                  child: const Text('Start a conversation')),
            ],
          ],
        ),
      ),
    );
  }
}
