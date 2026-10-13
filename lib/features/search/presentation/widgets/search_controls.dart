import 'package:flutter/material.dart';
import 'package:smart_search_app/design_system/nexa_theme.dart';

class SearchGlassIconButton extends StatelessWidget {
  const SearchGlassIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return NexaGlass(
      color: NexaColors.glassQuiet,
      blur: 16,
      borderRadius: BorderRadius.circular(24),
      child: SizedBox.square(
        dimension: 48,
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}

class SearchScopeOption extends StatelessWidget {
  const SearchScopeOption({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: (selected ? NexaColors.cyan : NexaColors.textSecondary)
                    .withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 21,
                color: selected ? NexaColors.cyan : NexaColors.textSecondary,
              ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: NexaColors.textTertiary,
                        ),
                  ),
                ],
              ),
            ),
            Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.chevron_right_rounded,
              color: selected ? NexaColors.cyan : NexaColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

class SearchVoiceLevelIndicator extends StatelessWidget {
  const SearchVoiceLevelIndicator(
      {super.key, required this.level, required this.active});

  final double level;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final normalized = active ? level.clamp(0.08, 1.0) : 0.08;
    return Semantics(
      label: active ? 'Microphone level active' : 'Microphone idle',
      child: SizedBox(
        width: 30,
        height: 28,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(5, (index) {
            final multiplier = index.isEven ? 0.65 : 1.0;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              width: 3,
              height: 6 + (18 * normalized * multiplier),
              decoration: BoxDecoration(
                color: NexaColors.cyan,
                borderRadius: BorderRadius.circular(3),
              ),
            );
          }),
        ),
      ),
    );
  }
}
