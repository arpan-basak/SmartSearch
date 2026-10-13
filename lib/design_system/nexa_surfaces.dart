import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:smart_search_app/design_system/nexa_theme.dart';

/// Resolution-independent atmosphere; never paints the light layers at startup.
class NexaAtmosphere extends StatelessWidget {
  const NexaAtmosphere({super.key, this.quiet = false});

  final bool quiet;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ColoredBox(
        color: NexaColors.canvas,
        child: NexaVisualEffects.enabledOf(context)
            ? DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.6, -0.92),
                    radius: quiet ? 0.95 : 1.25,
                    colors: [
                      quiet ? const Color(0xFF18233E) : const Color(0xFF294AA0),
                      quiet ? NexaColors.canvas : const Color(0xFF151E3A),
                      NexaColors.canvas,
                    ],
                    stops: const [0, 0.5, 1],
                  ),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(-1.1, -0.15),
                      radius: 0.85,
                      colors: [
                        const Color(0xFF7461D9)
                            .withValues(alpha: quiet ? 0.04 : 0.17),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: const SizedBox.expand(),
                ),
              )
            : const SizedBox.expand(),
      ),
    );
  }
}

class NexaLuminousBorder extends StatelessWidget {
  const NexaLuminousBorder({super.key, required this.child, this.radius = 32});

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final effects = NexaVisualEffects.enabledOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: effects
              ? const [
                  Color(0xFFB789D9),
                  Color(0xFF6576CC),
                  Color(0xFF4383FF),
                  Color(0xFF9DC9FF)
                ]
              : const [Color(0xFF343D59), Color(0xFF343D59)],
        ),
        boxShadow: effects
            ? const [
                BoxShadow(
                    color: Color(0x285657DC), blurRadius: 26, spreadRadius: 1),
                BoxShadow(color: Color(0x164487FF), blurRadius: 8),
              ]
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.all(1.2),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF101623),
            borderRadius: BorderRadius.circular(radius - 1.2),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// The signal is decorative. The adjacent status and transcript carry semantics.
class NexaSignal extends StatelessWidget {
  const NexaSignal(
      {super.key, this.size = 160, this.phase = 0, this.level = 0});

  final double size;
  final double phase;
  final double level;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: size,
          child: NexaVisualEffects.enabledOf(context)
              ? CustomPaint(painter: _SignalPainter(phase, level))
              : const Icon(Icons.graphic_eq_rounded,
                  color: NexaColors.info, size: 38),
        ),
      ),
    );
  }
}

class _SignalPainter extends CustomPainter {
  const _SignalPainter(this.phase, this.level);
  final double phase;
  final double level;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * 0.29;
    final bounds = Rect.fromCircle(center: center, radius: size.width / 2);
    canvas.drawCircle(
        center,
        size.width / 2,
        Paint()
          ..shader = const RadialGradient(colors: [
            Color(0x605477EA),
            Color(0x205A68D7),
            Colors.transparent
          ]).createShader(bounds));
    for (var ring = 0; ring < 5; ring++) {
      for (var i = 0; i < 96; i++) {
        final angle = i / 96 * math.pi * 2;
        final wave = math.sin(angle * 3 + phase * math.pi * 2 + ring * 0.6);
        final distance =
            radius + ring * size.width * 0.022 + wave * (2 + level * 5);
        final point =
            center + Offset(math.cos(angle), math.sin(angle)) * distance;
        canvas.drawCircle(
            point,
            ring == 0 ? 1.2 : 0.8,
            Paint()
              ..color = Color.lerp(const Color(0xFFB8B1FF),
                      const Color(0xFF65B6FF), (math.sin(angle) + 1) / 2)!
                  .withValues(
                      alpha: (0.7 - ring * 0.1 + wave * 0.1).clamp(0, 1)));
      }
    }
    canvas.drawCircle(
        center,
        radius * 0.88,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(-0.35, -0.5),
            colors: [
              Color(0xFF91B5FF),
              Color(0xFF6479D6),
              Color(0xFF323960),
              Color(0xFF171D32)
            ],
            stops: [0, 0.35, 0.77, 1],
          ).createShader(Rect.fromCircle(center: center, radius: radius)));
  }

  @override
  bool shouldRepaint(_SignalPainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.level != level;
}

class NexaSuggestionCard extends StatelessWidget {
  const NexaSuggestionCard(
      {super.key,
      required this.icon,
      required this.title,
      required this.subtitle,
      required this.onTap,
      this.color = NexaColors.info});

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 158,
      child: Material(
        color: const Color(0xB3182031),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: const BorderSide(color: Color(0x1AFFFFFF)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(icon, color: color, size: 23),
                const Spacer(),
                const Icon(Icons.north_east_rounded,
                    size: 16, color: NexaColors.textTertiary)
              ]),
              const Spacer(),
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(subtitle,
                  style: const TextStyle(
                      color: NexaColors.textSecondary, fontSize: 12)),
            ]),
          ),
        ),
      ),
    );
  }
}
