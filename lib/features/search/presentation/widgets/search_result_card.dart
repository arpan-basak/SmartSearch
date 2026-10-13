import 'package:flutter/material.dart';
import 'package:smart_search_app/design_system/nexa_theme.dart';
import 'package:smart_search_app/features/search/models/search_result.dart';
import 'package:smart_search_app/features/search/presentation/widgets/search_result_artwork.dart';

class SearchResultCard extends StatelessWidget {
  final SearchResult result;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onArtworkNeeded;
  final ValueChanged<SearchResult>? onContactAction;

  const SearchResultCard(
      {super.key,
      required this.result,
      required this.onTap,
      this.onLongPress,
      this.onArtworkNeeded,
      this.onContactAction});

  @override
  Widget build(BuildContext context) {
    if (onArtworkNeeded != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => onArtworkNeeded?.call());
    }
    if (result.contactActions.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(result.title, style: Theme.of(context).textTheme.titleMedium),
          Text(result.subtitle),
          Wrap(
              spacing: 8,
              children: result.contactActions
                  .map((action) => TextButton.icon(
                        onPressed: () => onContactAction?.call(action),
                        icon: Icon(action.icon, size: 18),
                        label: Text(action.title.startsWith('WhatsApp')
                            ? 'WhatsApp'
                            : action.title.startsWith('Call')
                                ? 'Call'
                                : 'Message'),
                      ))
                  .toList()),
        ]),
      );
    }
    final actionLabel = _actionLabel(result);
    final accent = switch (result.kind) {
      ResultKind.action => NexaColors.success,
      ResultKind.app => NexaColors.warning,
      ResultKind.document => NexaColors.iris,
      ResultKind.web => NexaColors.info,
    };
    final actionIcon = switch (actionLabel) {
      'Call' => Icons.call_rounded,
      'Message' => Icons.send_rounded,
      'Play' => Icons.play_arrow_rounded,
      _ => Icons.arrow_outward_rounded,
    };

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        constraints: const BoxConstraints(minHeight: 72),
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: result.recommendedContact
                  ? accent.withValues(alpha: 0.38)
                  : const Color(0x14FFFFFF),
            ),
          ),
        ),
        child: Row(
          children: [
            SearchResultArtwork(result: result, accent: accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(result.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 16)),
                  if (result.recommendedContact)
                    Text(
                      'Best match',
                      style: TextStyle(
                        color: accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  if (result.subtitle.isNotEmpty)
                    Text(
                      result.subtitle,
                      maxLines: result.kind == ResultKind.document ? 4 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: NexaColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                ],
              ),
            ),
            IconButton.filledTonal(
              tooltip: actionLabel,
              onPressed: onTap,
              style: IconButton.styleFrom(
                backgroundColor: accent.withValues(alpha: 0.11),
                foregroundColor: accent,
              ),
              icon: Icon(actionIcon, size: 19),
            ),
          ],
        ),
      ),
    );
  }

  String _actionLabel(SearchResult result) {
    if (result.kind == ResultKind.app) return 'Open';
    if (result.kind == ResultKind.document) return 'Open';
    if (result.url?.scheme == 'tel' || result.title.startsWith('Call ')) {
      return 'Call';
    }
    if (result.url?.scheme == 'sms' || result.title.startsWith('Message ')) {
      return 'Message';
    }
    if (result.url?.scheme == 'music') return 'Play';
    if (result.title.startsWith('WhatsApp ')) return 'Message';
    return 'Open';
  }
}
