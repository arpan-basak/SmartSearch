import 'package:flutter/material.dart';
import 'package:smart_search_app/design_system/nexa_theme.dart';
import 'package:smart_search_app/features/commands/domain/universal_action.dart';
import 'package:smart_search_app/features/knowledge/domain/knowledge_answer.dart';

class SearchUnderstoodCommandCard extends StatelessWidget {
  const SearchUnderstoodCommandCard({
    super.key,
    required this.intent,
    this.contactMatchCount = 0,
  });

  final UniversalIntent intent;
  final int contactMatchCount;

  @override
  Widget build(BuildContext context) {
    final description = switch (intent.type) {
      UniversalIntentType.callContact => 'Direct call • ${intent.target}',
      UniversalIntentType.whatsappContact => 'WhatsApp • ${intent.target}',
      UniversalIntentType.smsContact => 'SMS • ${intent.target}',
      UniversalIntentType.openApp => 'Open app • ${intent.target}',
      UniversalIntentType.searchInApp =>
        'Search ${intent.target} • ${intent.message}',
      UniversalIntentType.openWebsite => 'Open website • ${intent.target}',
      UniversalIntentType.webSearch => 'Google search • ${intent.target}',
      UniversalIntentType.searchDocuments => 'Search files • ${intent.target}',
      UniversalIntentType.playMusic => 'Play music • ${intent.target}',
      UniversalIntentType.navigatePlace => 'Directions • ${intent.target}',
      UniversalIntentType.unknown => '',
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: NexaColors.cyan.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome_rounded,
              color: NexaColors.cyan, size: 18),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              contactMatchCount > 1
                  ? '$description - choose one of $contactMatchCount matches'
                  : description,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class SearchConversationQuestion extends StatelessWidget {
  const SearchConversationQuestion({super.key, required this.query});

  final String query;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: NexaColors.blue.withValues(alpha: 0.22),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(6),
                bottomLeft: Radius.circular(18),
                bottomRight: Radius.circular(18),
              ),
              border: Border.all(
                color: NexaColors.blue.withValues(alpha: 0.32),
              ),
            ),
            child: Text(
              query,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
}

class SearchKnowledgeAnswerCard extends StatelessWidget {
  const SearchKnowledgeAnswerCard({super.key, required this.answer});

  final KnowledgeAnswer answer;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        label: '${answer.headline}. ${answer.body}',
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: NexaColors.raised,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0x1F53D8FF)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.auto_awesome_rounded,
                      color: NexaColors.cyan, size: 18),
                  SizedBox(width: 8),
                  Text(
                    'From your device',
                    style: TextStyle(
                      color: NexaColors.cyan,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                answer.headline,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                answer.body,
                maxLines: 7,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: NexaColors.textSecondary,
                  fontSize: 14,
                  height: 1.45,
                ),
              ),
              if (answer.relationships.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: answer.relationships
                      .map((reason) => Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 9, vertical: 6),
                            decoration: BoxDecoration(
                              color: NexaColors.iris.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text(
                              reason,
                              style: const TextStyle(
                                color: NexaColors.textSecondary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ))
                      .toList(),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                'Evidence: ${answer.evidenceLabels.join(' • ')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: NexaColors.textTertiary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      );
}
