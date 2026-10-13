import 'package:flutter_test/flutter_test.dart';
import 'package:smart_search_app/features/commands/domain/universal_action.dart';

void main() {
  group('offline command pipeline', () {
    test('keeps clear commands on the deterministic path', () {
      final command = CommandPipeline.interpret('Call Rahul');

      expect(command.intent.type, UniversalIntentType.callContact);
      expect(command.intent.target, 'Rahul');
      expect(command.source, CommandUnderstandingSource.deterministic);
      expect(command.confidence, 1);
      expect(command.requiresConfirmation, isTrue);
      expect(command.isValid, isTrue);
    });

    test('understands a conversational call request locally', () {
      final command = CommandPipeline.interpret(
        'I was wondering if you could give Rahul a call',
      );

      expect(command.intent.type, UniversalIntentType.callContact);
      expect(command.intent.target, 'Rahul');
      expect(command.source, CommandUnderstandingSource.localNlp);
      expect(command.confidence, greaterThan(0.8));
    });

    test('extracts recipient and message from conversational requests', () {
      final whatsApp = CommandPipeline.interpret(
        'I was wondering if you could send Rahul a WhatsApp message saying I am late',
      );
      final sms = CommandPipeline.interpret(
        'Would you mind texting Priya saying the meeting starts at five',
      );

      expect(whatsApp.intent.type, UniversalIntentType.whatsappContact);
      expect(whatsApp.intent.target, 'Rahul');
      expect(whatsApp.intent.message, 'I am late');
      expect(whatsApp.source, CommandUnderstandingSource.localNlp);
      expect(whatsApp.requiresConfirmation, isTrue);
      expect(sms.intent.type, UniversalIntentType.smsContact);
      expect(sms.intent.target, 'Priya');
      expect(sms.intent.message, 'the meeting starts at five');
      expect(sms.source, CommandUnderstandingSource.localNlp);
    });

    test('reduces a complex document request to useful searchable slots', () {
      final command = CommandPipeline.interpret(
        'I need you to find the document where I wrote the project budget',
      );

      expect(command.intent.type, UniversalIntentType.searchDocuments);
      expect(
        command.intent.target,
        'the document where I wrote the project budget',
      );
      expect(command.source, CommandUnderstandingSource.localNlp);
      expect(command.isValid, isTrue);
    });

    test('understands conversational app, navigation, web, and music requests',
        () {
      final examples = <String, UniversalIntentType>{
        'Could you please bring up Spotify': UniversalIntentType.openApp,
        'Would you mind showing me how to get to Victoria Memorial':
            UniversalIntentType.navigatePlace,
        'Do me a favour and find the best cafes online':
            UniversalIntentType.webSearch,
        'When you have a moment put on Blinding Lights':
            UniversalIntentType.playMusic,
      };

      for (final example in examples.entries) {
        final command = CommandPipeline.interpret(example.key);
        expect(command.intent.type, example.value, reason: example.key);
        expect(command.source, CommandUnderstandingSource.localNlp,
            reason: example.key);
      }
    });

    test('produces a versioned structured command for app execution', () {
      final command = CommandPipeline.interpret(
        'open Amazon and search for wireless headphones',
      );
      final json = command.toJson();

      expect(json['schemaVersion'], 1);
      expect(json['intent'], 'searchInApp');
      expect(json['target'], 'Amazon');
      expect(json['message'], 'wireless headphones');
      expect(json['source'], 'deterministic');
      expect(json['valid'], isTrue);
    });

    test('validator blocks incomplete commands from reaching the executor', () {
      final command = CommandValidator.validate(
        const UniversalIntent(
          type: UniversalIntentType.searchInApp,
          rawText: 'search in Amazon',
          target: 'Amazon',
        ),
        source: CommandUnderstandingSource.localNlp,
        confidence: 0.7,
      );

      expect(command.isValid, isFalse);
      expect(command.validationError, 'missing_search_query');
      expect(command.intent.type, UniversalIntentType.unknown);
    });

    test('does not invent an action for an unsupported sentence', () {
      final command = CommandPipeline.interpret(
        'This sentence has no requested action at all',
      );

      expect(command.intent.type, UniversalIntentType.unknown);
      expect(command.confidence, 0);
    });
  });
}
