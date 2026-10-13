import 'package:flutter_test/flutter_test.dart';
import 'package:smart_search_app/features/commands/domain/universal_action.dart';

void main() {
  test('song discovery phrases produce a clean music query', () {
    for (final phrase in [
      'find song Believer',
      'search music Believer',
      'search for song Believer',
      'song Believer',
      'play song Believer'
    ]) {
      final intent = UniversalActionParser.parse(phrase);
      expect(intent.type, UniversalIntentType.playMusic, reason: phrase);
      expect(intent.target, 'Believer', reason: phrase);
    }
  });
  test('parses direct contact actions and draft messages', () {
    final call = UniversalActionParser.parse('Call Rahul');
    expect(call.type, UniversalIntentType.callContact);
    expect(call.target, 'Rahul');

    final sms = UniversalActionParser.parse('SMS to Rahul saying I am late');
    expect(sms.type, UniversalIntentType.smsContact);
    expect(sms.target, 'Rahul');
    expect(sms.message, 'I am late');

    final whatsapp =
        UniversalActionParser.parse('Open WhatsApp chat with Rahul');
    expect(whatsapp.type, UniversalIntentType.whatsappContact);
    expect(whatsapp.target, 'Rahul');
  });

  test('understands natural call and WhatsApp sentence variants', () {
    for (final phrase in [
      'I want to call Rahul',
      'Please dial Rahul',
      'Make a call to Rahul',
      'Call this person Rahul please',
      'Could you please call Rahul',
    ]) {
      final intent = UniversalActionParser.parse(phrase);
      expect(intent.type, UniversalIntentType.callContact, reason: phrase);
      expect(intent.target, 'Rahul', reason: phrase);
    }

    for (final phrase in [
      'Open WhatsApp message for Rahul',
      'I want to open a WhatsApp chat with Rahul',
      'Send a WhatsApp to Rahul',
      'Message Rahul on WhatsApp',
    ]) {
      final intent = UniversalActionParser.parse(phrase);
      expect(intent.type, UniversalIntentType.whatsappContact, reason: phrase);
      expect(intent.target, 'Rahul', reason: phrase);
    }
  });

  test('extracts a most-used selector from natural contact commands', () {
    for (final phrase in [
      'call the most called Anish',
      'call my most contacted Anish',
      'call the Anish that I call the most',
      'call Anish I phone most often',
    ]) {
      final intent = UniversalActionParser.parse(phrase);
      expect(intent.type, UniversalIntentType.callContact, reason: phrase);
      expect(intent.target, 'Anish', reason: phrase);
      expect(intent.filters['contactSelection'], 'most_used', reason: phrase);
    }
  });

  test('parses app, website, web, music, and navigation actions', () {
    expect(UniversalActionParser.parse('open Amazon').type,
        UniversalIntentType.openApp);
    final appSearch = UniversalActionParser.parse(
      'open Amazon and search for wireless headphones',
    );
    expect(appSearch.type, UniversalIntentType.searchInApp);
    expect(appSearch.target, 'Amazon');
    expect(appSearch.message, 'wireless headphones');
    expect(UniversalActionParser.parse('open example.com').type,
        UniversalIntentType.openWebsite);
    expect(UniversalActionParser.parse('search example.com').type,
        UniversalIntentType.openWebsite);
    expect(UniversalActionParser.parse('search Flutter widgets').type,
        UniversalIntentType.webSearch);
    expect(UniversalActionParser.parse('google search Flutter widgets').type,
        UniversalIntentType.webSearch);
    expect(UniversalActionParser.parse('play Blinding Lights').type,
        UniversalIntentType.playMusic);
    expect(UniversalActionParser.parse('navigate to Victoria Memorial').type,
        UniversalIntentType.navigatePlace);
  });

  test('extracts structured document filters', () {
    final intent = UniversalActionParser.parse(
      'Show flight tickets from Kolkata to Delhi on 2026-07-14',
    );
    expect(intent.type, UniversalIntentType.searchDocuments);
    expect(intent.filters['category'], 'travel_ticket');
    expect(intent.filters['subtype'], 'flight');
    expect(intent.filters['from'], 'Kolkata');
    expect(intent.filters['to'], 'Delhi');
    expect(intent.filters['date'], '2026-07-14');
  });

  test('understands natural spoken train ticket routes', () {
    final direct = UniversalActionParser.parse(
      'Find the train tickets from Katpadi to Nagpur',
    );
    expect(direct.type, UniversalIntentType.searchDocuments);
    expect(direct.filters['category'], 'travel_ticket');
    expect(direct.filters['subtype'], 'train');
    expect(direct.filters['from'], 'Katpadi');
    expect(direct.filters['to'], 'Nagpur');

    final conversational = UniversalActionParser.parse(
      'Okay Apex AI, look for railway booking between Katpadi and Nagpur',
    );
    expect(conversational.type, UniversalIntentType.searchDocuments);
    expect(conversational.filters['subtype'], 'train');
    expect(conversational.filters['from'], 'Katpadi');
    expect(conversational.filters['to'], 'Nagpur');
  });

  test('normalizes common railway station speech mishearings', () {
    final intent = UniversalActionParser.parse(
      'find train tickets from cut body to nag poor',
    );
    expect(intent.filters['from'], 'Katpadi');
    expect(intent.filters['to'], 'Nagpur');
    expect(
      SpokenCommandNlp.normalizeTranscript('call Cut Body'),
      'call Cut Body',
    );
    final perambur = UniversalActionParser.parse(
      'find train ticket from Katpadi to Preambur',
    );
    expect(perambur.filters['to'], 'Perambur');
  });

  group('contact resolver', () {
    const contacts = <ContactCandidate>[
      ContactCandidate(
        id: '1',
        displayName: 'Surya, Jay',
        phone: '1111111111',
      ),
      ContactCandidate(
        id: '2',
        displayName: 'Anish M-I-C-V-I-T',
        phone: '2222222222',
      ),
      ContactCandidate(
        id: '3',
        displayName: 'Yashish',
        phone: '3333333333',
      ),
    ];

    test('matches reordered, initial-separated, and misheard names', () {
      expect(ContactResolver.resolve('Jay Surya', contacts).first.candidate.id,
          '1');
      expect(
          ContactResolver.resolve('Anish MICVIT', contacts).first.candidate.id,
          '2');
      expect(
          ContactResolver.resolve('Yashas', contacts).first.candidate.id, '3');
    });

    test('uses local aliases, frequency, and recency for personal ranking', () {
      final now = DateTime(2026, 7, 22);
      final matches = ContactResolver.resolve(
        'David',
        <ContactCandidate>[
          const ContactCandidate(
            id: 'george',
            displayName: 'David George',
            phone: '4444444444',
          ),
          ContactCandidate(
            id: 'new-york',
            displayName: 'David New York',
            phone: '5555555555',
            aliases: const <String>['David'],
            usageCount: 18,
            lastSelectedAt: now.subtract(const Duration(days: 1)),
          ),
        ],
        now: now,
      );

      expect(matches.first.candidate.id, 'new-york');
      expect(matches.first.matchedAlias, isTrue);
      expect(ContactResolver.shouldAutoSelect(matches), isTrue);
    });

    test('does not auto-select when several first-name matches are close', () {
      final matches = ContactResolver.resolve(
        'Anish',
        const <ContactCandidate>[
          ContactCandidate(
            id: 'a',
            displayName: 'Anish S',
            phone: '6666666666',
          ),
          ContactCandidate(
            id: 'b',
            displayName: 'Anish SP',
            phone: '7777777777',
          ),
        ],
      );

      expect(matches, hasLength(2));
      expect(ContactResolver.shouldAutoSelect(matches), isFalse);
    });

    test('returns every match and uses recency only for equal similarity', () {
      final allMatches = ContactResolver.resolve(
        'Alex',
        List<ContactCandidate>.generate(
          9,
          (index) => ContactCandidate(
            id: '$index',
            displayName: 'Alex Contact $index',
            phone: '90000000$index',
          ),
        ),
      );
      expect(allMatches, hasLength(9));

      final now = DateTime(2026, 9, 5);
      final tiedMatches = ContactResolver.resolve(
        'Alex',
        <ContactCandidate>[
          ContactCandidate(
            id: 'older',
            displayName: 'Alex One',
            phone: '9000000010',
            lastSelectedAt: now.subtract(const Duration(days: 2)),
          ),
          ContactCandidate(
            id: 'newer',
            displayName: 'Alex Two',
            phone: '9000000011',
            lastSelectedAt: now.subtract(const Duration(hours: 1)),
          ),
        ],
        now: now,
      );
      expect(tiedMatches.first.candidate.id, 'newer');
    });

    test('finds a single most frequently used contact', () {
      final matches = ContactResolver.resolve(
        'Anish',
        const <ContactCandidate>[
          ContactCandidate(
            id: 'mic',
            displayName: 'Anish MIC',
            phone: '6666666666',
            usageCount: 14,
          ),
          ContactCandidate(
            id: 'mishra',
            displayName: 'Anish Mishra',
            phone: '7777777777',
            usageCount: 3,
          ),
          ContactCandidate(
            id: 'nigam',
            displayName: 'Anish Nigam',
            phone: '8888888888',
            usageCount: 1,
          ),
        ],
      );

      expect(
        ContactResolver.mostFrequentlyUsed(matches)?.candidate.id,
        'mic',
      );
    });
  });
}
