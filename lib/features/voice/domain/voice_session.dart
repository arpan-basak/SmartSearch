import 'package:smart_search_app/features/commands/domain/universal_action.dart';

enum VoiceSessionPhase {
  idle,
  listening,
  processing,
  awaitingFollowUp,
  confirming,
  error,
}

enum VoiceFollowUpKind {
  command,
  correction,
  selectResult,
  confirm,
  cancel,
  repeat,
  undo,
  stop,
  clarification,
}

class VoiceFollowUpResolution {
  const VoiceFollowUpResolution({
    required this.kind,
    this.commandText = '',
    this.resultIndex,
    this.message = '',
  });

  final VoiceFollowUpKind kind;
  final String commandText;
  final int? resultIndex;
  final String message;
}

enum VoiceTranscriptRejection {
  none,
  empty,
  missingWakePhrase,
  probableNoise,
  tooShort,
}

class VoiceTranscriptAssessment {
  const VoiceTranscriptAssessment({
    required this.text,
    required this.rejection,
  });

  final String text;
  final VoiceTranscriptRejection rejection;

  bool get accepted => rejection == VoiceTranscriptRejection.none;
}

/// Rejects common accidental activations before any command can reach the
/// action executor. This is intentionally conservative for low-confidence,
/// short transcripts, which are frequently produced by background speech.
abstract final class VoiceTranscriptGate {
  static VoiceTranscriptAssessment assess(
    String raw, {
    required double confidence,
    required bool requireWakePhrase,
    bool responseWasRequested = false,
  }) {
    var spoken = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (spoken.isEmpty) {
      return const VoiceTranscriptAssessment(
        text: '',
        rejection: VoiceTranscriptRejection.empty,
      );
    }

    final wakePhrase = RegExp(
      r'^(?:hey\s+)?apex(?:\s+ai)?[\s,.:;-]+',
      caseSensitive: false,
    );
    final hasWakePhrase = wakePhrase.hasMatch(spoken);
    if (hasWakePhrase) spoken = spoken.replaceFirst(wakePhrase, '').trim();
    final text = SpokenCommandNlp.normalizeTranscript(spoken).trim();
    if (requireWakePhrase && !hasWakePhrase) {
      return VoiceTranscriptAssessment(
        text: text,
        rejection: VoiceTranscriptRejection.missingWakePhrase,
      );
    }
    if (text.isEmpty) {
      return const VoiceTranscriptAssessment(
        text: '',
        rejection: VoiceTranscriptRejection.tooShort,
      );
    }

    final words = text.split(RegExp(r'\s+'));
    if (confidence >= 0 && confidence < 0.28 && words.length <= 4) {
      return VoiceTranscriptAssessment(
        text: text,
        rejection: VoiceTranscriptRejection.probableNoise,
      );
    }
    if (text.length == 1 && !RegExp(r'[0-9]').hasMatch(text)) {
      return VoiceTranscriptAssessment(
        text: text,
        rejection: VoiceTranscriptRejection.tooShort,
      );
    }
    return VoiceTranscriptAssessment(
      text: text,
      rejection: VoiceTranscriptRejection.none,
    );
  }
}

/// Retains only the minimum local context needed to repair the previous turn.
/// It never stores microphone audio or sends conversation data off-device.
class VoiceConversationContext {
  StructuredCommand? _lastCommand;

  StructuredCommand? get lastCommand => _lastCommand;

  void record(StructuredCommand command) {
    if (command.isValid && command.intent.isExplicit) _lastCommand = command;
  }

  void clear() => _lastCommand = null;

  void restore(StructuredCommand? command) => _lastCommand = command;

  String? get repeatCommandText {
    final command = _lastCommand;
    return command == null ? null : commandTextFor(command.intent);
  }

  VoiceFollowUpResolution resolve(
    String raw, {
    required int resultCount,
    bool awaitingConfirmation = false,
  }) {
    final text = SpokenCommandNlp.normalizeTranscript(raw).trim();
    final normalized = text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

    if (_matches(normalized, const {
      'yes',
      'yeah',
      'yep',
      'correct',
      'confirm',
      'go ahead',
      'do it',
      'please do',
    })) {
      return const VoiceFollowUpResolution(kind: VoiceFollowUpKind.confirm);
    }
    if (_matches(normalized, const {
      'no',
      'nope',
      'cancel',
      'cancel that',
      'never mind',
      'nevermind',
      'do not',
      "don't",
    })) {
      return VoiceFollowUpResolution(
        kind: awaitingConfirmation
            ? VoiceFollowUpKind.cancel
            : VoiceFollowUpKind.clarification,
        message: awaitingConfirmation
            ? 'Cancelled.'
            : 'Tell me what you want changed.',
      );
    }
    if (_matches(normalized, const {
      'stop',
      'stop listening',
      'end conversation',
      'that is all',
      "that's all",
      'done',
    })) {
      return const VoiceFollowUpResolution(kind: VoiceFollowUpKind.stop);
    }
    if (RegExp(r'^(?:undo|undo that|go back|take that back)$')
        .hasMatch(normalized)) {
      return const VoiceFollowUpResolution(kind: VoiceFollowUpKind.undo);
    }
    if (RegExp(r'^(?:repeat|repeat that|do that again|same again)$')
        .hasMatch(normalized)) {
      return const VoiceFollowUpResolution(kind: VoiceFollowUpKind.repeat);
    }

    final requestedOrdinal = _resultOrdinal(normalized);
    if (requestedOrdinal != null) {
      final ordinal =
          requestedOrdinal == 0x7fffffff ? resultCount - 1 : requestedOrdinal;
      if (ordinal >= 0 && ordinal < resultCount) {
        return VoiceFollowUpResolution(
          kind: VoiceFollowUpKind.selectResult,
          resultIndex: ordinal,
        );
      }
      return VoiceFollowUpResolution(
        kind: VoiceFollowUpKind.clarification,
        message: resultCount == 0
            ? 'There are no results to choose from.'
            : 'There are only $resultCount results. Choose one of those.',
      );
    }

    final previous = _lastCommand?.intent;
    if (previous != null) {
      final channel = RegExp(
        r'^(?:no[, ]+)?(?:actually[, ]+)?(?:use|make\s+it|send\s+it\s+by)\s+(whats?\s*app|sms|text|call)(?:\s+instead)?$',
        caseSensitive: false,
      ).firstMatch(text);
      if (channel != null) {
        final requested = channel.group(1)!.toLowerCase();
        final type = requested.startsWith('what')
            ? UniversalIntentType.whatsappContact
            : requested == 'call'
                ? UniversalIntentType.callContact
                : UniversalIntentType.smsContact;
        return VoiceFollowUpResolution(
          kind: VoiceFollowUpKind.correction,
          commandText: commandTextFor(
            UniversalIntent(
              type: type,
              rawText: text,
              target: previous.target,
              message: previous.message,
            ),
          ),
        );
      }

      final replacement = _replacementText(text);
      if (replacement != null) {
        final parsed = CommandPipeline.interpret(replacement);
        if (parsed.intent.isExplicit) {
          return VoiceFollowUpResolution(
            kind: VoiceFollowUpKind.correction,
            commandText: replacement,
          );
        }
        return VoiceFollowUpResolution(
          kind: VoiceFollowUpKind.correction,
          commandText: commandTextFor(
            UniversalIntent(
              type: previous.type,
              rawText: text,
              target: replacement,
              message: previous.message,
              filters: previous.filters,
            ),
          ),
        );
      }

      final change = RegExp(
        r'^(?:no[, ]+)?(?:please\s+)?(?:change|replace)\s+(.+?)\s+(?:to|with)\s+(.+)$',
        caseSensitive: false,
      ).firstMatch(text);
      if (change != null) {
        final from = change.group(1)!.trim();
        final to = change.group(2)!.trim();
        final changedTarget = previous.target.replaceFirst(
          RegExp(RegExp.escape(from), caseSensitive: false),
          to,
        );
        return VoiceFollowUpResolution(
          kind: VoiceFollowUpKind.correction,
          commandText: commandTextFor(
            UniversalIntent(
              type: previous.type,
              rawText: text,
              target: changedTarget == previous.target ? to : changedTarget,
              message: previous.message,
              filters: previous.filters,
            ),
          ),
        );
      }
    }

    if (RegExp(
      r"^(?:no[, ]+)?(?:that(?:\s+is|'s)?\s+)?(?:was\s+)?(?:wrong|not\s+right|incorrect)$",
      caseSensitive: false,
    ).hasMatch(text)) {
      return const VoiceFollowUpResolution(
        kind: VoiceFollowUpKind.clarification,
        message: 'Tell me what I should change.',
      );
    }

    return VoiceFollowUpResolution(
      kind: VoiceFollowUpKind.command,
      commandText: text,
    );
  }

  static bool _matches(String value, Set<String> choices) =>
      choices.contains(value.replaceAll(RegExp(r'[.!?]+$'), '').trim());

  static int? _resultOrdinal(String text) {
    final match = RegExp(
      r'^(?:(?:open|choose|select|pick|tap|show)\s+)?(?:the\s+)?(first|1st|one|second|2nd|two|third|3rd|three|fourth|4th|four|fifth|5th|five|last)(?:\s+(?:result|one|option|item))?$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return null;
    return switch (match.group(1)!.toLowerCase()) {
      'first' || '1st' || 'one' => 0,
      'second' || '2nd' || 'two' => 1,
      'third' || '3rd' || 'three' => 2,
      'fourth' || '4th' || 'four' => 3,
      'fifth' || '5th' || 'five' => 4,
      'last' => 0x7fffffff,
      _ => null,
    };
  }

  static String? _replacementText(String text) {
    final match = RegExp(
      r'^(?:no[, ]+)?(?:actually[, ]+)?(?:(?:i\s+)?meant|make\s+that|search\s+for|look\s+for)\s+(.+?)(?:\s+instead)?$',
      caseSensitive: false,
    ).firstMatch(text);
    final replacement = match?.group(1)?.trim();
    return replacement == null || replacement.isEmpty ? null : replacement;
  }

  static String commandTextFor(UniversalIntent intent) => switch (intent.type) {
        UniversalIntentType.callContact => 'call ${intent.target}',
        UniversalIntentType.whatsappContact => intent.message.isEmpty
            ? 'whatsapp ${intent.target}'
            : 'whatsapp ${intent.target} saying ${intent.message}',
        UniversalIntentType.smsContact => intent.message.isEmpty
            ? 'sms to ${intent.target}'
            : 'sms to ${intent.target} saying ${intent.message}',
        UniversalIntentType.openApp => 'open ${intent.target}',
        UniversalIntentType.searchInApp =>
          'open ${intent.target} and search for ${intent.message}',
        UniversalIntentType.openWebsite => 'open ${intent.target}',
        UniversalIntentType.webSearch => 'search ${intent.target}',
        UniversalIntentType.searchDocuments => 'find document ${intent.target}',
        UniversalIntentType.playMusic => 'play ${intent.target}',
        UniversalIntentType.navigatePlace => 'navigate to ${intent.target}',
        UniversalIntentType.unknown => intent.rawText,
      };
}
