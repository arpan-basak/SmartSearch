import 'package:flutter_test/flutter_test.dart';
import 'package:smart_search_app/features/commands/domain/universal_action.dart';
import 'package:smart_search_app/features/voice/domain/voice_session.dart';

void main() {
  group('voice transcript gate', () {
    test('strips the wake phrase before command parsing', () {
      final result = VoiceTranscriptGate.assess(
        'Hey Apex AI, call Arpan',
        confidence: 0.91,
        requireWakePhrase: true,
      );

      expect(result.accepted, isTrue);
      expect(result.text, 'call Arpan');
    });

    test('rejects another speaker without the required wake phrase', () {
      final result = VoiceTranscriptGate.assess(
        'call Arpan',
        confidence: 0.96,
        requireWakePhrase: true,
      );

      expect(result.rejection, VoiceTranscriptRejection.missingWakePhrase);
    });

    test('keeps requested confirmations protected by the wake phrase', () {
      final result = VoiceTranscriptGate.assess(
        'yes',
        confidence: 0.9,
        requireWakePhrase: true,
        responseWasRequested: true,
      );

      expect(result.rejection, VoiceTranscriptRejection.missingWakePhrase);
    });

    test('rejects a short low-confidence noise hypothesis', () {
      final result = VoiceTranscriptGate.assess(
        'uh call',
        confidence: 0.12,
        requireWakePhrase: false,
      );

      expect(result.rejection, VoiceTranscriptRejection.probableNoise);
    });
  });

  group('voice conversation repairs', () {
    final context = VoiceConversationContext();

    setUp(() {
      context
        ..clear()
        ..record(CommandPipeline.interpret('search cafes in Bangalore'));
    });

    test('changes only the previous target for a bare correction', () {
      final result = context.resolve(
        'No, I meant cafes in Mysore instead',
        resultCount: 3,
      );

      expect(result.kind, VoiceFollowUpKind.correction);
      expect(result.commandText, 'search cafes in Mysore');
    });

    test('selects a result by ordinal', () {
      final result = context.resolve('open the second result', resultCount: 3);

      expect(result.kind, VoiceFollowUpKind.selectResult);
      expect(result.resultIndex, 1);
    });

    test('does not select an ordinal outside the visible results', () {
      final result = context.resolve('open the fifth result', resultCount: 2);

      expect(result.kind, VoiceFollowUpKind.clarification);
    });

    test('switches the delivery channel while retaining recipient and text',
        () {
      context.record(CommandPipeline.interpret(
        'sms to Arpan saying I will be late',
      ));

      final result = context.resolve('use WhatsApp instead', resultCount: 1);

      expect(result.kind, VoiceFollowUpKind.correction);
      expect(result.commandText, 'whatsapp Arpan saying I will be late');
    });

    test('distinguishes confirmation cancellation from a correction prompt',
        () {
      expect(
        context.resolve('no', resultCount: 1, awaitingConfirmation: true).kind,
        VoiceFollowUpKind.cancel,
      );
      expect(
        context.resolve('no', resultCount: 1).kind,
        VoiceFollowUpKind.clarification,
      );
    });

    test('recognizes stop repeat and undo controls', () {
      expect(context.resolve('stop listening', resultCount: 1).kind,
          VoiceFollowUpKind.stop);
      expect(context.resolve('do that again', resultCount: 1).kind,
          VoiceFollowUpKind.repeat);
      expect(context.resolve('undo that', resultCount: 1).kind,
          VoiceFollowUpKind.undo);
    });
  });
}
