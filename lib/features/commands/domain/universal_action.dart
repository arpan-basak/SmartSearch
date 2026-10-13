import 'dart:math' as math;

enum UniversalIntentType {
  callContact,
  whatsappContact,
  smsContact,
  openApp,
  searchInApp,
  openWebsite,
  webSearch,
  searchDocuments,
  playMusic,
  navigatePlace,
  unknown,
}

enum CommandUnderstandingSource { deterministic, localNlp }

class UniversalIntent {
  const UniversalIntent({
    required this.type,
    required this.rawText,
    this.target = '',
    this.message = '',
    this.filters = const <String, String>{},
  });

  final UniversalIntentType type;
  final String rawText;
  final String target;
  final String message;
  final Map<String, String> filters;

  bool get isExplicit => type != UniversalIntentType.unknown;
}

/// The stable, app-understandable language produced by the command pipeline.
/// UI and platform code execute these validated fields, never arbitrary code.
class StructuredCommand {
  const StructuredCommand({
    required this.intent,
    required this.source,
    required this.confidence,
    required this.requiresConfirmation,
    this.validationError,
  });

  static const schemaVersion = 1;
  final UniversalIntent intent;
  final CommandUnderstandingSource source;
  final double confidence;
  final bool requiresConfirmation;
  final String? validationError;

  bool get isValid => validationError == null;

  Map<String, Object> toJson() => {
        'schemaVersion': schemaVersion,
        'intent': intent.type.name,
        'rawText': intent.rawText,
        'target': intent.target,
        'message': intent.message,
        'filters': intent.filters,
        'confidence': confidence,
        'source': source.name,
        'requiresConfirmation': requiresConfirmation,
        'valid': isValid,
        if (validationError != null) 'validationError': validationError!,
      };
}

abstract final class CommandValidator {
  static StructuredCommand validate(
    UniversalIntent intent, {
    required CommandUnderstandingSource source,
    required double confidence,
  }) {
    String? error;
    if (intent.type != UniversalIntentType.unknown &&
        intent.target.trim().isEmpty) {
      error = 'missing_target';
    } else if (intent.type == UniversalIntentType.searchInApp &&
        intent.message.trim().isEmpty) {
      error = 'missing_search_query';
    } else if (intent.target.length > 500 || intent.message.length > 2000) {
      error = 'command_too_long';
    }

    final safeIntent = error == null
        ? intent
        : UniversalIntent(
            type: UniversalIntentType.unknown,
            rawText: intent.rawText,
            target: intent.rawText.trim(),
          );
    return StructuredCommand(
      intent: safeIntent,
      source: source,
      confidence: confidence.clamp(0, 1).toDouble(),
      requiresConfirmation: _requiresConfirmation(safeIntent),
      validationError: error,
    );
  }

  static bool _requiresConfirmation(UniversalIntent intent) =>
      switch (intent.type) {
        UniversalIntentType.callContact => true,
        UniversalIntentType.smsContact ||
        UniversalIntentType.whatsappContact =>
          intent.message.isNotEmpty,
        _ => false,
      };
}

/// Offline-first orchestration: exact parsing wins, with local NLP used only
/// when the deterministic layer cannot understand the request.
abstract final class CommandPipeline {
  static StructuredCommand interpret(String input) {
    final deterministic = UniversalActionParser._parseDeterministic(input);
    final shouldRefineDocument =
        deterministic.type == UniversalIntentType.searchDocuments &&
            RegExp(
              r"^(?:i\s+(?:need|want)\s+you\s+to|help\s+me|where\s+(?:is|did)|i\s+(?:cannot|can't)\s+remember)",
              caseSensitive: false,
            ).hasMatch(input.trim());
    if (shouldRefineDocument) {
      final local = LocalIntentInterpreter.interpret(input);
      if (local?.intent.type == UniversalIntentType.searchDocuments) {
        return CommandValidator.validate(
          local!.intent,
          source: CommandUnderstandingSource.localNlp,
          confidence: local.confidence,
        );
      }
    }
    if (deterministic.type != UniversalIntentType.unknown) {
      return CommandValidator.validate(
        deterministic,
        source: CommandUnderstandingSource.deterministic,
        confidence: 1,
      );
    }

    final local = LocalIntentInterpreter.interpret(input);
    if (local != null) {
      return CommandValidator.validate(
        local.intent,
        source: CommandUnderstandingSource.localNlp,
        confidence: local.confidence,
      );
    }

    return CommandValidator.validate(
      deterministic,
      source: CommandUnderstandingSource.deterministic,
      confidence: 0,
    );
  }
}

class LocalIntentMatch {
  const LocalIntentMatch(this.intent, this.confidence);
  final UniversalIntent intent;
  final double confidence;
}

/// Lightweight, explainable natural-language fallback that runs on-device.
abstract final class LocalIntentInterpreter {
  static LocalIntentMatch? interpret(String input) {
    final raw = input.trim();
    final text = SpokenCommandNlp.normalizeTranscript(raw);
    if (text.isEmpty) return null;
    final canonical = _canonicalCommand(text);
    if (canonical == null) return null;
    final intent = UniversalActionParser._parseDeterministic(canonical.command);
    if (intent.type == UniversalIntentType.unknown) return null;
    return LocalIntentMatch(
      UniversalIntent(
        type: intent.type,
        rawText: raw,
        target: intent.target,
        message: intent.message,
        filters: intent.filters,
      ),
      canonical.confidence,
    );
  }

  static ({String command, double confidence})? _canonicalCommand(
    String text,
  ) {
    final normalized = text
        .replaceFirst(
          RegExp(
            r'^(?:i\s+(?:was\s+)?wonder(?:ing)?\s+(?:if|whether)\s+you\s+could|would\s+you\s+mind|do\s+me\s+a\s+favou?r\s+and|when\s+you\s+(?:can|have\s+a\s+moment)|could\s+you\s+please)\s+',
            caseSensitive: false,
          ),
          '',
        )
        .replaceFirst(
          RegExp(r'\s+(?:for\s+me\s*)?please$', caseSensitive: false),
          '',
        )
        .trim();

    final call = RegExp(
      r'^(?:give|place|make)\s+(.+?)\s+(?:a\s+)?call$|^(?:get|put)\s+me\s+(?:in\s+touch|through)\s+(?:with|to)\s+(.+)$|^(?:let\s+me|i\s+(?:need|want|would\s+like)\s+to)\s+(?:speak|talk)\s+(?:with|to)\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (call != null) {
      return (
        command: 'call ${call.group(1) ?? call.group(2) ?? call.group(3)}',
        confidence: 0.86,
      );
    }

    final whatsApp = RegExp(
      r'^(?:send|write|drop)\s+(.+?)\s+(?:a\s+)?whats?\s*app(?:\s+message)?(?:\s+(?:saying|that\s+says|with\s+message)\s+(.+))?$|^(?:get\s+in\s+touch\s+with|message)\s+(.+?)\s+(?:using|on|through)\s+whats?\s*app$',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (whatsApp != null) {
      final target = whatsApp.group(1) ?? whatsApp.group(3);
      final message = whatsApp.group(2);
      return (
        command: message == null
            ? 'whatsapp $target'
            : 'whatsapp $target saying $message',
        confidence: 0.88,
      );
    }

    final sms = RegExp(
      r'^(?:send|write|drop)\s+(.+?)\s+(?:a\s+)?(?:text|sms)(?:\s+message)?(?:\s+(?:saying|that\s+says|with\s+message)\s+(.+))?$|^text(?:ing)?\s+(.+?)(?:\s+(?:saying|that\s+says|with\s+message)\s+(.+))?$',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (sms != null) {
      final target = sms.group(1) ?? sms.group(3);
      final message = sms.group(2) ?? sms.group(4);
      return (
        command: message == null
            ? 'sms to $target'
            : 'sms to $target saying $message',
        confidence: 0.86,
      );
    }

    final document = RegExp(
      r"^(?:i\s+(?:need|want)\s+you\s+to\s+|help\s+me\s+|where\s+(?:is|did\s+i\s+(?:save|put))\s+|i\s+(?:cannot|can't)\s+remember\s+where\s+i\s+(?:saved|put)\s+)(?:find|locate|show|get|open)?\s*(.+)$",
      caseSensitive: false,
    ).firstMatch(normalized);
    final documentTarget = document?.group(1)?.trim();
    if (documentTarget != null &&
        UniversalActionParser._looksLikeDocumentRequest(documentTarget)) {
      return (command: 'find $documentTarget', confidence: 0.86);
    }

    final open = RegExp(
      r'^(?:bring\s+up|show\s+me|switch\s+to|take\s+me\s+to)\s+(?:the\s+)?(.+?)(?:\s+app)?$',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (open != null) {
      return (command: 'open ${open.group(1)}', confidence: 0.82);
    }

    final directions = RegExp(
      r"^(?:show(?:ing)?\s+me\s+how\s+to\s+get|help\s+me\s+get|what(?:\s+is|'s)\s+the\s+(?:way|route))\s+to\s+(.+)$",
      caseSensitive: false,
    ).firstMatch(normalized);
    if (directions != null) {
      return (
        command: 'navigate to ${directions.group(1)}',
        confidence: 0.88,
      );
    }

    final web = RegExp(
      r'^(?:find|look\s+for|show\s+me|tell\s+me)\s+(.+?)\s+(?:online|on\s+the\s+(?:web|internet))$|^(?:can\s+you\s+)?(?:check|search)\s+(?:online|the\s+(?:web|internet))\s+(?:for\s+)?(.+)$',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (web != null) {
      return (
        command: 'search ${web.group(1) ?? web.group(2)}',
        confidence: 0.84,
      );
    }

    final music = RegExp(
      r'^(?:put\s+on|i\s+(?:want|would\s+like)\s+to\s+(?:hear|listen\s+to))\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (music != null) {
      return (command: 'play ${music.group(1)}', confidence: 0.82);
    }

    return null;
  }
}

/// Lightweight, on-device NLP for cleaning speech transcripts and extracting
/// entities that speech recognizers commonly format in different ways.
abstract final class SpokenCommandNlp {
  static String normalizeTranscript(String input) {
    var text = input
        .trim()
        .replaceAll(RegExp(r'[,;!?]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ');

    text = text.replaceFirst(
      RegExp(
        r'^(?:(?:hey|hi|hello|ok|okay)\s+)?(?:apex\s+ai|apex|nexa|smart\s+search|assistant)[,:]?\s+',
        caseSensitive: false,
      ),
      '',
    );

    const replacements = <(String, String)>[
      (r'\bring\s+up\b', 'call'),
      (r'\blook\s+for\b', 'find'),
      (r'\blook\s+up\b', 'search'),
      (
        r'\brailway\s+(?:ticket|tickets|booking|reservation)\b',
        'train tickets'
      ),
    ];
    for (final replacement in replacements) {
      text = text.replaceAll(
        RegExp(replacement.$1, caseSensitive: false),
        replacement.$2,
      );
    }
    if (RegExp(r'\b(?:train|ticket|railway|booking|reservation)\b',
            caseSensitive: false)
        .hasMatch(text)) {
      const stationReplacements = <(String, String)>[
        (r'\bnag\s+poor\b', 'Nagpur'),
        (r'\b(?:cat|cut)\s+(?:body|party|padi)\b', 'Katpadi'),
        (r'\bpreambur\b', 'Perambur'),
      ];
      for (final replacement in stationReplacements) {
        text = text.replaceAll(
          RegExp(replacement.$1, caseSensitive: false),
          replacement.$2,
        );
      }
    }
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static (String, String)? extractRoute(String input) {
    final text = normalizeTranscript(input);
    final patterns = <RegExp>[
      RegExp(
        r'\bfrom\s+(.+?)\s+to\s+(.+?)(?=\s+(?:on|dated|booked|for|please)\b|$)',
        caseSensitive: false,
      ),
      RegExp(
        r'\bbetween\s+(.+?)\s+and\s+(.+?)(?=\s+(?:on|dated|booked|for|please)\b|$)',
        caseSensitive: false,
      ),
      RegExp(
        r'\bleaving\s+(.+?)\s+for\s+(.+?)(?=\s+(?:on|dated|please)\b|$)',
        caseSensitive: false,
      ),
      RegExp(
        r'\b(?:tickets?|booking|reservation)\s+(?:from\s+)?(.+?)\s+to\s+(.+?)(?=\s+(?:on|dated|booked|please)\b|$)',
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      final from = match?.group(1)?.trim();
      final to = match?.group(2)?.trim();
      if (from != null && from.isNotEmpty && to != null && to.isNotEmpty) {
        return (from, to);
      }
    }
    return null;
  }
}

class UniversalActionParser {
  const UniversalActionParser._();

  static UniversalIntent parse(String input) =>
      CommandPipeline.interpret(input).intent;

  static UniversalIntent _parseDeterministic(String input) {
    final raw = input.trim();
    var text = SpokenCommandNlp.normalizeTranscript(raw);
    if (text.isEmpty) {
      return UniversalIntent(
        type: UniversalIntentType.unknown,
        rawText: raw,
      );
    }

    // Speech and typed commands often include a polite request around the
    // actual action. Remove that wrapper before intent matching so the same
    // action is recognized across natural sentence variations.
    text = text
        .replaceFirst(
          RegExp(
            r'^(?:please\s+)?(?:i\s+want\s+to|i\s+need\s+to|i\s+would\s+like\s+to|can\s+you|could\s+you|would\s+you|help\s+me)\s+',
            caseSensitive: false,
          ),
          '',
        )
        .replaceFirst(RegExp(r'^please\s+', caseSensitive: false), '')
        .trim();

    Match? match;
    match = RegExp(
      r'^(?:call|phone|dial|ring)(?:\s+(?:this|the))?(?:\s+(?:person|contact))?(?:\s+(?:named|called|for))?\s+(.+?)(?:\s+please)?$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null) {
      return _contactIntent(raw, match.group(1));
    }
    match = RegExp(r'^make\s+(?:a\s+)?call\s+to\s+(.+?)(?:\s+please)?$',
            caseSensitive: false)
        .firstMatch(text);
    if (match != null) {
      return _contactIntent(raw, match.group(1));
    }

    match = RegExp(
      r'^(?:open\s+(?:a\s+)?)?whats?\s*app(?:\s+(?:message|chat|conversation))?(?:\s+(?:for|with|to|of))?\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null) {
      final parts = _splitMessage(match.group(1) ?? '');
      return UniversalIntent(
        type: UniversalIntentType.whatsappContact,
        rawText: raw,
        target: parts.$1,
        message: parts.$2,
      );
    }

    match = RegExp(
      r'^(?:send|message|chat)\s+(?:a\s+)?whats?\s*app(?:\s+(?:message|chat|to|with))?\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null) {
      final parts = _splitMessage(match.group(1) ?? '');
      return UniversalIntent(
        type: UniversalIntentType.whatsappContact,
        rawText: raw,
        target: parts.$1,
        message: parts.$2,
      );
    }

    match = RegExp(
      r'^(?:message|chat)\s+(.+?)\s+on\s+whats?\s*app$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null) {
      final parts = _splitMessage(match.group(1) ?? '');
      return UniversalIntent(
        type: UniversalIntentType.whatsappContact,
        rawText: raw,
        target: parts.$1,
        message: parts.$2,
      );
    }

    match = RegExp(
      r'^(?:sms|text|message)(?:\s+(?:a\s+)?text)?(?:\s+to)?\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null) {
      final parts = _splitMessage(match.group(1) ?? '');
      return UniversalIntent(
        type: UniversalIntentType.smsContact,
        rawText: raw,
        target: parts.$1,
        message: parts.$2,
      );
    }

    match = RegExp(
      r'^(?:navigate|directions?|take me)(?:\s+to)\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null) {
      return _targeted(UniversalIntentType.navigatePlace, raw, match.group(1));
    }

    match = RegExp(
            r'^(?:(?:play|listen\s+to)(?:\s+(?:song|music))?|(?:(?:find|search)(?:\s+for)?\s+)?(?:song|music)(?:\s+named)?)\s+(.+)$',
            caseSensitive: false)
        .firstMatch(text);
    if (match != null) {
      return _targeted(UniversalIntentType.playMusic, raw, match.group(1));
    }

    match = RegExp(
      r'^(?:google|web)\s+search(?:\s+for)?\s+(.+)$|^search(?:\s+for)?\s+(.+)\s+(?:on|in)\s+google$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null) {
      return _targeted(
        UniversalIntentType.webSearch,
        raw,
        match.group(1) ?? match.group(2),
      );
    }

    match = RegExp(
      r'^(?:open|launch|start)\s+(?:the\s+)?(.+?)\s+(?:app\s+)?(?:and|then)\s+(?:search|find)(?:\s+for)?\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null) {
      return UniversalIntent(
        type: UniversalIntentType.searchInApp,
        rawText: raw,
        target: (match.group(1) ?? '').trim(),
        message: (match.group(2) ?? '').trim(),
      );
    }

    match = RegExp(
      r'^(?:search|open|visit|go\s+to)\s+((?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?:/\S*)?)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null || _looksLikeDomain(text)) {
      return _targeted(
        UniversalIntentType.openWebsite,
        raw,
        match?.group(1) ?? text,
      );
    }

    match = RegExp(r'^(?:open|launch|start)\s+(?:the\s+)?(.+?)(?:\s+app)?$',
            caseSensitive: false)
        .firstMatch(text);
    if (match != null) {
      return _targeted(UniversalIntentType.openApp, raw, match.group(1));
    }

    if (_looksLikeDocumentRequest(text)) {
      final target = text
          .replaceFirst(
            RegExp(
              r'^(?:please\s+)?(?:show|find|locate|get|give|search)(?:\s+me)?(?:\s+for)?\s+',
              caseSensitive: false,
            ),
            '',
          )
          .trim();
      return UniversalIntent(
        type: UniversalIntentType.searchDocuments,
        rawText: raw,
        target: target.isEmpty ? text : target,
        filters: _documentFilters(text),
      );
    }

    match = RegExp(r'^search(?:\s+for)?\s+(.+)$', caseSensitive: false)
        .firstMatch(text);
    if (match != null) {
      return _targeted(UniversalIntentType.webSearch, raw, match.group(1));
    }

    return UniversalIntent(
      type: UniversalIntentType.unknown,
      rawText: raw,
      target: text,
    );
  }

  static UniversalIntent _targeted(
    UniversalIntentType type,
    String raw,
    String? target,
  ) {
    return UniversalIntent(
      type: type,
      rawText: raw,
      target: (target ?? '').trim(),
    );
  }

  static UniversalIntent _contactIntent(String raw, String? rawTarget) {
    var target = (rawTarget ?? '').trim();
    var selection = '';
    final selectorPatterns = <RegExp>[
      RegExp(
        r'^(?:my\s+|the\s+)?(?:most\s+(?:called|dialed|dialled|contacted)|frequently\s+called|usually\s+called|often\s+called)\s+(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'^(?:my\s+)?(.+?)\s+(?:that|who|which)\s+i\s+(?:call|phone|dial|contact)\s+(?:the\s+)?most(?:\s+often|\s+of\s+the\s+time)?$',
        caseSensitive: false,
      ),
      RegExp(
        r'^(?:my\s+)?(.+?)\s+i\s+(?:call|phone|dial|contact)\s+(?:the\s+)?most(?:\s+often|\s+of\s+the\s+time)?$',
        caseSensitive: false,
      ),
    ];
    for (final pattern in selectorPatterns) {
      final selector = pattern.firstMatch(target);
      if (selector == null) continue;
      final selectedTarget = selector.group(1)!.trim().replaceFirst(
            RegExp(r'^the\s+', caseSensitive: false),
            '',
          );
      if (RegExp(r'^(?:one|contact|person)$', caseSensitive: false)
          .hasMatch(selectedTarget)) {
        break;
      }
      target = selectedTarget;
      selection = 'most_used';
      break;
    }
    return UniversalIntent(
      type: UniversalIntentType.callContact,
      rawText: raw,
      target: target,
      filters: {
        if (selection.isNotEmpty) 'contactSelection': selection,
      },
    );
  }

  static (String, String) _splitMessage(String input) {
    final match = RegExp(
      r'^(.+?)\s+(?:saying|that says|with message)\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(input.trim());
    if (match == null) return (input.trim(), '');
    return (match.group(1)!.trim(), match.group(2)!.trim());
  }

  static bool _looksLikeDomain(String text) => RegExp(
        r'^(?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?:/\S*)?$',
        caseSensitive: false,
      ).hasMatch(text);

  static bool _looksLikeDocumentRequest(String text) {
    final lower = text.toLowerCase();
    const concepts = <String>{
      'file',
      'files',
      'document',
      'documents',
      'pdf',
      'certificate',
      'certificates',
      'assignment',
      'assignments',
      'ticket',
      'tickets',
      'e-ticket',
      'boarding pass',
      'invoice',
      'receipt',
      'resume',
      'bank statement',
      'notes',
      'marksheet',
      'mark sheet',
      'statement of marks',
      'academic record',
      'scorecard',
      'spreadsheet',
      'presentation',
    };
    return concepts.any(lower.contains) ||
        RegExp(
          r'\b(?:train|flight|railway)\s+(?:booking|reservation)\b',
          caseSensitive: false,
        ).hasMatch(text);
  }

  static Map<String, String> _documentFilters(String text) {
    final filters = <String, String>{};
    final lower = text.toLowerCase();

    const categoryTerms = <String, String>{
      'certificate': 'certificate',
      'assignment': 'assignment',
      'boarding pass': 'travel_ticket',
      'flight ticket': 'travel_ticket',
      'train ticket': 'travel_ticket',
      'rail ticket': 'travel_ticket',
      'railway ticket': 'travel_ticket',
      'ticket': 'travel_ticket',
      'invoice': 'invoice',
      'receipt': 'receipt',
      'resume': 'resume',
      'bank statement': 'bank_statement',
      'notes': 'study_material',
      'marksheet': 'education_record',
      'mark sheet': 'education_record',
      'statement of marks': 'education_record',
      'academic record': 'education_record',
      'scorecard': 'education_record',
      'spreadsheet': 'spreadsheet',
      'presentation': 'presentation',
    };
    for (final entry in categoryTerms.entries) {
      if (lower.contains(entry.key)) {
        filters['category'] = entry.value;
        break;
      }
    }
    if (lower.contains('flight') || lower.contains('boarding pass')) {
      filters['subtype'] = 'flight';
    } else if (lower.contains('train') || lower.contains('irctc')) {
      filters['subtype'] = 'train';
    }

    final route = SpokenCommandNlp.extractRoute(text);
    if (route != null) {
      filters['from'] = route.$1;
      filters['to'] = route.$2;
    }

    final date = RegExp(
      r'\b(?:\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}[-/]\d{1,2}[-/](?:\d{2}|\d{4})|\d{1,2}\s+(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)[a-z]*\s+(?:\d{2}|\d{4}))\b',
      caseSensitive: false,
    ).firstMatch(text);
    if (date != null) filters['date'] = date.group(0)!.trim();
    return filters;
  }
}

String normalizeEntity(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

class ContactCandidate {
  const ContactCandidate({
    required this.id,
    required this.displayName,
    required this.phone,
    this.aliases = const <String>[],
    this.usageCount = 0,
    this.lastSelectedAt,
    this.isFavorite = false,
  });

  final String id;
  final String displayName;
  final String phone;
  final List<String> aliases;
  final int usageCount;
  final DateTime? lastSelectedAt;
  final bool isFavorite;
}

class ContactMatch {
  const ContactMatch({
    required this.candidate,
    required this.score,
    required this.textScore,
    required this.matchedAlias,
  });

  final ContactCandidate candidate;
  final double score;
  final double textScore;
  final bool matchedAlias;
}

class ContactResolver {
  const ContactResolver._();

  static List<ContactMatch> resolve(
    String spokenName,
    Iterable<ContactCandidate> contacts, {
    int? limit,
    DateTime? now,
  }) {
    final queryForms = _nameForms(spokenName);
    if (queryForms.isEmpty) return const <ContactMatch>[];
    final resolvedAt = now ?? DateTime.now();
    final matches = <ContactMatch>[];

    for (final contact in contacts) {
      final displayForms = _nameForms(contact.displayName);
      var bestTextScore = _bestFormScore(queryForms, displayForms);
      var matchedAlias = false;

      for (final alias in contact.aliases) {
        final aliasScore = _bestFormScore(queryForms, _nameForms(alias));
        if (aliasScore > bestTextScore) {
          bestTextScore = aliasScore;
          matchedAlias = true;
        }
      }

      if (bestTextScore < 0.42) continue;

      final usageBoost = math.min(contact.usageCount, 25) * 0.006;
      final recencyBoost = _recencyBoost(contact.lastSelectedAt, resolvedAt);
      final aliasBoost = matchedAlias ? 0.12 : 0.0;
      final favoriteBoost = contact.isFavorite ? 0.06 : 0.0;
      matches.add(ContactMatch(
        candidate: contact,
        textScore: bestTextScore,
        score: bestTextScore +
            usageBoost +
            recencyBoost +
            aliasBoost +
            favoriteBoost,
        matchedAlias: matchedAlias,
      ));
    }

    matches.sort((a, b) {
      // A closer name match always wins. Only equally similar contacts use
      // recency as a tie-breaker, so a frequently used but weaker match does
      // not hide the person the user actually searched for.
      final bySimilarity = b.textScore.compareTo(a.textScore);
      if (bySimilarity != 0) return bySimilarity;
      final aTime = a.candidate.lastSelectedAt;
      final bTime = b.candidate.lastSelectedAt;
      if (aTime != null || bTime != null) {
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        final byRecency = bTime.compareTo(aTime);
        if (byRecency != 0) return byRecency;
      }
      return a.candidate.displayName
          .toLowerCase()
          .compareTo(b.candidate.displayName.toLowerCase());
    });

    final unique = <String, ContactMatch>{};
    for (final match in matches) {
      unique.putIfAbsent(match.candidate.id, () => match);
    }
    final allMatches = unique.values.toList();
    return limit == null ? allMatches : allMatches.take(limit).toList();
  }

  static bool shouldAutoSelect(List<ContactMatch> matches) {
    if (matches.isEmpty || matches.first.textScore < 0.90) return false;
    if (matches.length == 1) return true;
    return matches.first.score - matches[1].score >= 0.18;
  }

  static ContactMatch? mostFrequentlyUsed(List<ContactMatch> matches) {
    if (matches.isEmpty) return null;
    final ranked = [...matches]..sort((a, b) {
        final byUsage =
            b.candidate.usageCount.compareTo(a.candidate.usageCount);
        if (byUsage != 0) return byUsage;
        final aTime = a.candidate.lastSelectedAt;
        final bTime = b.candidate.lastSelectedAt;
        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });
    final winner = ranked.first;
    if (winner.candidate.usageCount <= 0) return null;
    if (ranked.length == 1) return winner;
    final runnerUp = ranked[1];
    if (winner.candidate.usageCount == runnerUp.candidate.usageCount) {
      return null;
    }
    return winner;
  }

  static double _bestFormScore(Set<String> queryForms, Set<String> nameForms) {
    if (queryForms.isEmpty || nameForms.isEmpty) return 0;
    var best = 0.0;
    for (final query in queryForms) {
      for (final name in nameForms) {
        best = math.max(best, _formScore(query, name));
      }
    }
    return best;
  }

  static double _formScore(String query, String name) {
    if (query == name) return 1;
    final queryTokens =
        query.split(' ').where((item) => item.isNotEmpty).toList();
    final nameTokens =
        name.split(' ').where((item) => item.isNotEmpty).toList();
    final queryCompact = queryTokens.join();
    final nameCompact = nameTokens.join();
    if (queryCompact == nameCompact) return 0.99;

    final querySet = queryTokens.toSet();
    final nameSet = nameTokens.toSet();
    if (querySet.length == nameSet.length && querySet.containsAll(nameSet)) {
      return 0.97;
    }
    if (querySet.isNotEmpty && nameSet.containsAll(querySet)) {
      return queryTokens.length == 1 ? 0.88 : 0.93;
    }
    if (name.startsWith('$query ') || nameCompact.startsWith(queryCompact)) {
      return 0.86;
    }
    if (name.contains(query) || nameCompact.contains(queryCompact)) {
      return 0.80;
    }

    final queryInitials = queryTokens.map((item) => item[0]).join();
    final nameInitials = nameTokens.map((item) => item[0]).join();
    if (queryCompact.length > 1 && queryCompact == nameInitials) return 0.82;
    if (nameCompact.length > 1 && nameCompact == queryInitials) return 0.82;

    var similarity = _editSimilarity(queryCompact, nameCompact);
    for (final queryToken in queryTokens) {
      for (final nameToken in nameTokens) {
        similarity = math.max(
          similarity,
          _editSimilarity(queryToken, nameToken) * 0.92,
        );
        if (_soundex(queryToken) == _soundex(nameToken) &&
            _soundex(queryToken).isNotEmpty) {
          similarity = math.max(similarity, 0.72);
        }
      }
    }
    return similarity;
  }

  static Set<String> _nameForms(String value) {
    final normalized = normalizeEntity(value);
    if (normalized.isEmpty) return const <String>{};
    final tokens = normalized.split(' ');
    final collapsedTokens = <String>[];
    final initials = StringBuffer();

    void flushInitials() {
      if (initials.isEmpty) return;
      collapsedTokens.add(initials.toString());
      initials.clear();
    }

    for (final token in tokens) {
      if (token.length == 1) {
        initials.write(token);
      } else {
        flushInitials();
        collapsedTokens.add(token);
      }
    }
    flushInitials();

    final collapsed = collapsedTokens.join(' ');
    final sortedTokens = [...collapsedTokens]..sort();
    return <String>{
      normalized,
      collapsed,
      sortedTokens.join(' '),
    }..removeWhere((item) => item.isEmpty);
  }

  static double _editSimilarity(String left, String right) {
    if (left == right) return 1;
    if (left.isEmpty || right.isEmpty) return 0;
    final previous = List<int>.generate(right.length + 1, (index) => index);
    for (var leftIndex = 1; leftIndex <= left.length; leftIndex++) {
      final current = List<int>.filled(right.length + 1, 0);
      current[0] = leftIndex;
      for (var rightIndex = 1; rightIndex <= right.length; rightIndex++) {
        final substitution =
            left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1;
        current[rightIndex] = math
            .min(
              math.min(current[rightIndex - 1] + 1, previous[rightIndex] + 1),
              previous[rightIndex - 1] + substitution,
            )
            .toInt();
      }
      for (var index = 0; index < previous.length; index++) {
        previous[index] = current[index];
      }
    }
    final longest = math.max(left.length, right.length);
    return 1 - (previous[right.length] / longest);
  }

  static String _soundex(String value) {
    final letters = normalizeEntity(value).replaceAll(' ', '');
    if (letters.isEmpty) return '';
    const groups = <String, String>{
      'b': '1',
      'f': '1',
      'p': '1',
      'v': '1',
      'c': '2',
      'g': '2',
      'j': '2',
      'k': '2',
      'q': '2',
      's': '2',
      'x': '2',
      'z': '2',
      'd': '3',
      't': '3',
      'l': '4',
      'm': '5',
      'n': '5',
      'r': '6',
    };
    final output = StringBuffer(letters[0]);
    var previousCode = groups[letters[0]] ?? '';
    for (final letter in letters.substring(1).split('')) {
      final code = groups[letter] ?? '';
      if (code.isNotEmpty && code != previousCode) output.write(code);
      previousCode = code;
      if (output.length == 4) break;
    }
    return output.toString().padRight(4, '0');
  }

  static double _recencyBoost(DateTime? selectedAt, DateTime now) {
    if (selectedAt == null) return 0;
    final age = now.difference(selectedAt);
    if (age.isNegative || age <= const Duration(days: 1)) return 0.08;
    if (age <= const Duration(days: 7)) return 0.05;
    if (age <= const Duration(days: 30)) return 0.025;
    return 0;
  }
}
