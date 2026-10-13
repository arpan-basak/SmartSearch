import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:smart_search_app/features/search/models/search_result.dart';

class SearchResultArtwork extends StatelessWidget {
  const SearchResultArtwork(
      {super.key, required this.result, required this.accent});

  final SearchResult result;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final isDocument = result.kind == ResultKind.document;
    final dimension = isDocument ? 62.0 : 48.0;
    final encoded = result.previewBase64?.isNotEmpty == true
        ? result.previewBase64
        : result.iconBase64;
    Widget child = _fallback(isDocument);
    if (encoded?.isNotEmpty == true) {
      try {
        child = Image.memory(
          base64Decode(encoded!),
          fit: isDocument ? BoxFit.cover : BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _fallback(isDocument),
        );
      } on FormatException {
        child = _fallback(isDocument);
      }
    }

    return Semantics(
      image: encoded?.isNotEmpty == true,
      label: isDocument
          ? 'Preview of ${result.title}'
          : result.kind == ResultKind.app
              ? '${result.title} app logo'
              : null,
      child: Container(
        width: dimension,
        height: dimension,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: isDocument
              ? Border.all(color: Colors.white.withValues(alpha: 0.1))
              : null,
        ),
        child: child,
      ),
    );
  }

  Widget _fallback(bool isDocument) {
    if (!isDocument) {
      final icon = switch (result.url?.scheme) {
        'tel' => Icons.call_rounded,
        'sms' => Icons.sms_rounded,
        'whatsapp' => Icons.chat_rounded,
        'music' => Icons.music_note_rounded,
        _ => result.icon,
      };
      return Icon(icon, color: accent);
    }
    final extension = result.title.contains('.')
        ? result.title.split('.').last.toUpperCase()
        : 'FILE';
    return Stack(
      alignment: Alignment.center,
      children: [
        Icon(result.icon, color: accent, size: 28),
        Positioned(
          left: 5,
          right: 5,
          bottom: 3,
          child: Text(
            extension.length > 5 ? extension.substring(0, 5) : extension,
            textAlign: TextAlign.center,
            maxLines: 1,
            style: TextStyle(
              color: accent,
              fontSize: 8,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ],
    );
  }
}
