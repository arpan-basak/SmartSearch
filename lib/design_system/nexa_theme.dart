import 'dart:ui';

import 'package:flutter/material.dart';

abstract final class NexaAssets {
  static const ambientBackground =
      'assets/images/nexa_ambient_background_v2.webp';
}

abstract final class NexaColors {
  static const canvas = Color(0xFF090D13);
  static const canvasLight = Color(0xFFF4F7FB);
  static const glass = Color(0xDC121823);
  static const glassQuiet = Color(0xC2121823);
  static const raised = Color(0xFF151C27);
  static const soft = Color(0xFF202937);
  static const text = Color(0xFFF7F9FC);
  static const textSecondary = Color(0xFFB8C2D1);
  static const textTertiary = Color(0xFF7E8A9B);
  static const cyan = Color(0xFF57DDF7);
  static const blue = Color(0xFF386BFA);
  static const iris = Color(0xFF8A7CFF);
  static const success = Color(0xFF59D49C);
  static const warning = Color(0xFFF3B85B);
  static const error = Color(0xFFFF6D7C);
  static const info = Color(0xFF75A7FF);
}

abstract final class NexaTheme {
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: dark ? NexaColors.info : const Color(0xFF315ED2),
      onPrimary: dark ? NexaColors.canvas : Colors.white,
      primaryContainer:
          dark ? const Color(0xFF113946) : const Color(0xFFD3F5FC),
      onPrimaryContainer:
          dark ? const Color(0xFFBDF4FF) : const Color(0xFF003640),
      secondary: NexaColors.iris,
      onSecondary: Colors.white,
      secondaryContainer:
          dark ? const Color(0xFF2B2756) : const Color(0xFFE7E2FF),
      onSecondaryContainer:
          dark ? const Color(0xFFE7E2FF) : const Color(0xFF24204D),
      tertiary: NexaColors.success,
      onTertiary: NexaColors.canvas,
      tertiaryContainer:
          dark ? const Color(0xFF123B2E) : const Color(0xFFD7F8E9),
      onTertiaryContainer:
          dark ? const Color(0xFFC1F6DE) : const Color(0xFF083425),
      error: NexaColors.error,
      onError: Colors.white,
      errorContainer: dark ? const Color(0xFF4E2029) : const Color(0xFFFFD9DE),
      onErrorContainer:
          dark ? const Color(0xFFFFD9DE) : const Color(0xFF4E2029),
      surface: dark ? NexaColors.canvas : NexaColors.canvasLight,
      onSurface: dark ? NexaColors.text : const Color(0xFF121821),
      surfaceContainerHighest:
          dark ? NexaColors.raised : const Color(0xFFE9EDF4),
      onSurfaceVariant:
          dark ? NexaColors.textSecondary : const Color(0xFF4F5A69),
      outline: dark ? const Color(0x33FFFFFF) : const Color(0x240D1824),
      outlineVariant: dark ? const Color(0x18FFFFFF) : const Color(0x140D1824),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: dark ? NexaColors.text : NexaColors.canvas,
      onInverseSurface: dark ? NexaColors.canvas : NexaColors.text,
      inversePrimary: dark ? const Color(0xFF007B92) : NexaColors.cyan,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
    );

    return base.copyWith(
      chipTheme: ChipThemeData(
        backgroundColor: dark ? const Color(0xFF131C2A) : Colors.white,
        selectedColor: dark ? const Color(0xFF273E70) : const Color(0xFFDCE7FF),
        side: BorderSide(color: scheme.outlineVariant),
        shape: const StadiumBorder(),
        showCheckmark: false,
        labelStyle: TextStyle(color: scheme.onSurface, fontSize: 13),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      ),
      textTheme: base.textTheme.copyWith(
        displaySmall: base.textTheme.displaySmall?.copyWith(
          fontSize: 34,
          height: 1.16,
          fontWeight: FontWeight.w500,
          letterSpacing: -1.1,
        ),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontSize: 28,
          height: 1.2,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.8,
        ),
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontSize: 22,
          height: 1.27,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.35,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontSize: 18,
          height: 1.33,
          fontWeight: FontWeight.w700,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(
          fontSize: 16,
          height: 1.44,
          fontWeight: FontWeight.w500,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          fontSize: 14,
          height: 1.43,
          fontWeight: FontWeight.w500,
        ),
        labelLarge: base.textTheme.labelLarge?.copyWith(
          fontSize: 14,
          height: 1.2,
          fontWeight: FontWeight.w700,
        ),
        labelMedium: base.textTheme.labelMedium?.copyWith(
          fontSize: 12,
          height: 1.3,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 19,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.25,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 54),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 54),
          side: BorderSide(color: scheme.outline),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: dark ? NexaColors.raised : Colors.white,
        modalBackgroundColor: dark ? NexaColors.raised : Colors.white,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: dark ? const Color(0xFFF1F5FA) : NexaColors.raised,
        contentTextStyle: TextStyle(
          color: dark ? NexaColors.canvas : NexaColors.text,
          fontWeight: FontWeight.w600,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? NexaColors.raised : Colors.white,
        hintStyle: TextStyle(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.74),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
    );
  }
}

/// Lets the first usable frame paint without creating backdrop-filter passes.
/// The same controls remain interactive while decoration is enabled afterward.
class NexaVisualEffects extends InheritedWidget {
  const NexaVisualEffects({
    super.key,
    required this.enabled,
    required super.child,
  });

  final bool enabled;

  static bool enabledOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<NexaVisualEffects>()
          ?.enabled ??
      true;

  @override
  bool updateShouldNotify(NexaVisualEffects oldWidget) =>
      enabled != oldWidget.enabled;
}

class NexaGlass extends StatelessWidget {
  const NexaGlass({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(28)),
    this.padding,
    this.color = NexaColors.glass,
    this.blur = 22,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final Color color;
  final double blur;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        enabled: NexaVisualEffects.enabledOf(context),
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: borderRadius,
            border: Border.all(color: const Color(0x18FFFFFF)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x3D000000),
                blurRadius: 24,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
        ),
      ),
    );
  }
}

class NexaBrand extends StatelessWidget {
  const NexaBrand({
    super.key,
    this.compact = false,
    this.light = true,
  });

  final bool compact;
  final bool light;

  @override
  Widget build(BuildContext context) {
    final foreground =
        light ? Colors.white : Theme.of(context).colorScheme.onSurface;
    return Semantics(
      label: 'Apex AI',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(compact ? 10 : 14),
            child: Image.asset(
              'assets/images/app_logo.png',
              width: compact ? 34 : 44,
              height: compact ? 34 : 44,
              cacheWidth: compact ? 68 : 88,
              cacheHeight: compact ? 68 : 88,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Apex AI',
            style: TextStyle(
              color: foreground,
              fontSize: compact ? 16 : 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
            ),
          ),
        ],
      ),
    );
  }
}

class NexaSectionLabel extends StatelessWidget {
  const NexaSectionLabel(this.label, {super.key, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant
                      .withValues(alpha: 0.75),
                  letterSpacing: 1.15,
                ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class NexaPageHeader extends StatelessWidget {
  const NexaPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onBack,
    this.actions = const <Widget>[],
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (onBack != null)
              IconButton(
                tooltip: 'Back',
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back_rounded),
              )
            else
              const SizedBox(width: 12),
            const Spacer(),
            ...actions,
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontSize: 32)),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ]),
        ),
      ]),
    );
  }
}
