import 'package:flutter/material.dart';
import 'package:smart_search_app/design_system/nexa_theme.dart';

class SearchCompactStatusBanner extends StatelessWidget {
  const SearchCompactStatusBanner({
    super.key,
    required this.icon,
    required this.label,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String label;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: NexaGlass(
        color: NexaColors.glassQuiet,
        blur: 16,
        borderRadius: BorderRadius.circular(16),
        padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: NexaColors.cyan),
            const SizedBox(width: 9),
            Flexible(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: NexaColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (actionLabel != null && onAction != null)
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ),
      ),
    );
  }
}

class SearchNoResults extends StatelessWidget {
  const SearchNoResults({super.key, this.query = '', this.onReset});

  final String query;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 20),
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
                Icons.search_off_rounded,
                size: 30,
                color: NexaColors.cyan,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'No local matches',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 7),
            Text(
              query.isEmpty
                  ? 'Try another search or choose a different source.'
                  : 'Nothing available matches “$query” in this source.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: NexaColors.textSecondary,
                  ),
            ),
            if (onReset != null) ...[
              const SizedBox(height: 16),
              TextButton(
                onPressed: onReset,
                child: const Text('Search all sources'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
