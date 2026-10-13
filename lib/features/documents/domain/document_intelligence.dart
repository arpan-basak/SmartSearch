import 'dart:math' as math;

/// A compact, private description of what a document actually represents.
class DocumentContextProfile {
  const DocumentContextProfile({
    required this.category,
    required this.confidence,
    required this.summary,
    required this.keywords,
    this.signals = const <String>[],
    this.metadata = const <String, String>{},
  });

  final String category;
  final double confidence;
  final String summary;
  final List<String> keywords;
  final List<String> signals;
  final Map<String, String> metadata;

  String get label => DocumentIntelligence.categoryLabel(category);
}

/// Prepared once per document revision, retained in the search worker.
class PreparedDocumentSearch {
  PreparedDocumentSearch(String name, String content, this.profile)
      : nameText = DocumentIntelligence.normalize(name),
        body = DocumentIntelligence.normalize(content) {
    nameTokens = DocumentIntelligence._tokens(nameText);
    bodyTokens = DocumentIntelligence._tokens(body);
    documentTokens = {...nameTokens, ...bodyTokens, ...profile.keywords};
  }

  final DocumentContextProfile profile;
  final String nameText;
  final String body;
  late final Set<String> nameTokens;
  late final Set<String> bodyTokens;
  late final Set<String> documentTokens;
}

/// Local document classification and intent-aware ranking.
///
/// This deliberately uses several independent signals. A single incidental
/// word (for example "certificate" in an IRCTC ticket) cannot override strong
/// evidence that the document is a travel ticket.
class DocumentIntelligence {
  const DocumentIntelligence._();

  static const int profileVersion = 6;

  static const Map<String, Map<String, int>> _categorySignals = {
    'certificate': {
      'certificate of completion': 15,
      'certificate of achievement': 15,
      'certificate of participation': 14,
      'this is to certify': 15,
      'has successfully completed': 12,
      'successfully completed': 9,
      'is hereby awarded': 11,
      'presented to': 8,
      'awarded to': 8,
      'completion certificate': 14,
      'certificate': 3,
      'workshop': 2,
      'bootcamp': 2,
      'training': 2,
    },
    'travel_ticket': {
      'irctc': 18,
      'pnr': 14,
      'train number': 10,
      'train no': 10,
      'boarding': 7,
      'reservation': 7,
      'journey': 6,
      'coach': 5,
      'berth': 5,
      'passenger': 4,
      'fare': 4,
      'e ticket': 9,
      'flight ticket': 12,
      'air ticket': 12,
      'boarding pass': 14,
    },
    'assignment': {
      'assignment': 14,
      'digital assignment': 16,
      'submitted by': 7,
      'submitted to': 7,
      'course code': 6,
      'question 1': 4,
      'question 2': 4,
      'homework': 11,
      'lab exercise': 9,
    },
    'invoice': {
      'tax invoice': 16,
      'invoice number': 12,
      'invoice no': 12,
      'bill to': 8,
      'gstin': 10,
      'subtotal': 5,
      'amount due': 7,
    },
    'receipt': {
      'payment receipt': 15,
      'receipt number': 10,
      'transaction id': 7,
      'payment successful': 8,
      'paid amount': 7,
    },
    'resume': {
      'curriculum vitae': 18,
      'work experience': 10,
      'professional experience': 10,
      'career objective': 8,
      'education': 3,
      'skills': 3,
      'resume': 15,
    },
    'identity': {
      'aadhaar': 18,
      'passport number': 15,
      'identity card': 13,
      'date of birth': 4,
      'government of india': 5,
      'driving licence': 15,
      'driving license': 15,
    },
    'bank_statement': {
      'account statement': 15,
      'bank statement': 18,
      'account number': 7,
      'opening balance': 8,
      'closing balance': 8,
      'debit': 4,
      'credit': 4,
    },
    'study_material': {
      'lecture notes': 12,
      'study material': 14,
      'learning objectives': 7,
      'chapter': 3,
      'syllabus': 12,
      'curriculum': 12,
      'course outline': 14,
      'tutorial': 5,
    },
    'education_record': {
      'statement of marks': 18,
      'mark sheet': 18,
      'marksheet': 18,
      'academic record': 15,
      'board examination': 14,
      'board of secondary education': 15,
      'higher secondary': 12,
      'senior school certificate': 12,
      'class xii': 11,
      '12th': 9,
      'subject code': 7,
      'marks obtained': 10,
      'maximum marks': 8,
      'total marks': 8,
      'result': 3,
      'cbse': 8,
      'cisce': 8,
    },
  };

  static const Map<String, Set<String>> _concepts = {
    'certificate': {
      'certificate',
      'certification',
      'certified',
      'completion',
      'achievement',
      'participation',
      'award',
      'awarded',
      'workshop',
      'bootcamp',
      'training',
      'course',
      'class',
      'credential',
      'proof'
    },
    'assignment': {
      'assignment',
      'homework',
      'coursework',
      'exercise',
      'lab',
      'submission',
      'submitted',
      'da'
    },
    'travel_ticket': {
      'ticket',
      'travel',
      'train',
      'flight',
      'journey',
      'pnr',
      'irctc',
      'reservation',
      'boarding',
      'coach',
      'berth'
    },
    'invoice': {'invoice', 'bill', 'billing', 'gst', 'tax', 'amount'},
    'receipt': {'receipt', 'payment', 'paid', 'transaction', 'purchase'},
    'resume': {'resume', 'cv', 'experience', 'skills', 'career'},
    'identity': {'identity', 'id', 'aadhaar', 'passport', 'licence', 'license'},
    'bank_statement': {'bank', 'statement', 'account', 'debit', 'credit'},
    'study_material': {
      'notes',
      'lecture',
      'study',
      'syllabus',
      'curriculum',
      'outline',
      'tutorial'
    },
    'education_record': {
      'marksheet',
      'marks',
      'scorecard',
      'grade',
      'grades',
      'academic',
      'board',
      'exam',
      'examination',
      'result',
      '12th',
      'xii',
      'secondary',
    },
  };

  /// Subject concepts are soft evidence, not document-type constraints. They
  /// let a query such as "GPU notes" match a CUDA/warp/coalescing passage
  /// without treating every technical alias as a mandatory literal token.
  static const Map<String, Set<String>> _subjectConcepts = {
    'gpu_programming': {
      'gpu',
      'gpgpu',
      'cuda',
      'kernel',
      'kernels',
      'warp',
      'warps',
      'threadblock',
      'threadblocks',
      'coalesced',
      'coalescing',
      'multiprocessor',
      'multiprocessors',
    },
  };

  static const Set<String> _stopWords = {
    'a',
    'an',
    'and',
    'are',
    'as',
    'at',
    'be',
    'by',
    'for',
    'from',
    'has',
    'have',
    'i',
    'in',
    'is',
    'it',
    'me',
    'my',
    'of',
    'on',
    'or',
    'please',
    'show',
    'the',
    'this',
    'to',
    'was',
    'with',
    'file',
    'document',
    'find'
  };

  static DocumentContextProfile infer({
    required String name,
    required String mimeType,
    required String content,
  }) {
    final normalized = normalize('$name $content');
    final scores = <String, int>{};
    final evidence = <String, List<String>>{};

    for (final category in _categorySignals.entries) {
      var score = 0;
      final matches = <String>[];
      for (final signal in category.value.entries) {
        if (normalized.contains(signal.key)) {
          score += signal.value;
          matches.add(signal.key);
        }
      }
      scores[category.key] = score;
      evidence[category.key] = matches;
    }

    final travelEvidence = evidence['travel_ticket'] ?? const <String>[];
    const strongTravelEvidence = <String>{
      'irctc',
      'pnr',
      'train number',
      'train no',
      'e ticket',
      'flight ticket',
      'air ticket',
      'boarding pass',
    };
    if (!travelEvidence.any(strongTravelEvidence.contains) &&
        travelEvidence.length < 2) {
      scores['travel_ticket'] = 0;
      evidence['travel_ticket'] = const <String>[];
    }

    final lowerName = normalize(name);
    if (lowerName.contains('certificate')) {
      scores['certificate'] = (scores['certificate'] ?? 0) + 5;
    }
    if (lowerName.contains('ticket')) {
      scores['travel_ticket'] = (scores['travel_ticket'] ?? 0) + 5;
    }
    if (lowerName.contains('assignment')) {
      scores['assignment'] = (scores['assignment'] ?? 0) + 6;
    }
    if (mimeType.contains('spreadsheet') || lowerName.endsWith('xlsx')) {
      scores['spreadsheet'] = 7;
    }
    if (mimeType.contains('presentation') || lowerName.endsWith('pptx')) {
      scores['presentation'] = 7;
    }

    final ordered = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final best = ordered.isEmpty || ordered.first.value < 5
        ? const MapEntry('document', 0)
        : ordered.first;
    final second = ordered.length > 1 ? ordered[1].value : 0;
    final confidence = best.value == 0
        ? 0.25
        : (0.55 + best.value / 45 + (best.value - second) / 70)
            .clamp(0.55, 0.99)
            .toDouble();
    final keywords = _topKeywords(normalized, category: best.key);

    return DocumentContextProfile(
      category: best.key,
      confidence: confidence,
      summary: _summary(best.key, name, keywords),
      keywords: keywords,
      signals: evidence[best.key] ?? const <String>[],
      metadata: _extractMetadata(normalized, category: best.key),
    );
  }

  static int score({
    required String query,
    required String name,
    required String mimeType,
    required String content,
    required DocumentContextProfile profile,
    double semanticSimilarity = 0,
    int positiveFeedback = 0,
    int negativeFeedback = 0,
    PreparedDocumentSearch? prepared,
  }) {
    final q = normalize(query);
    if (q.isEmpty) return 0;
    final data = prepared ?? PreparedDocumentSearch(name, content, profile);
    final nameText = data.nameText;
    final body = data.body;
    final intent = _queryIntent(q);
    final softSubjectIntent = intent == 'study_material' &&
        !RegExp(r'\b(syllabus|curriculum|course outline)\b').hasMatch(q);
    var score = 0.0;

    if (nameText == q) score += 260;
    if (nameText.contains(q)) score += 170;
    if (body.contains(q)) score += 70;

    final queryTokens = _tokens(q);
    final documentTokens = data.documentTokens;
    if (!hasSubjectEvidence(query, name, content)) return 0;
    // “Syllabus” is more specific than generic notes or tutorials. Do not
    // promote an unrelated blank note/editor merely because it was broadly
    // classified as study material.
    final hasSyllabusEvidence = documentTokens.contains('syllabus') ||
        documentTokens.contains('curriculum') ||
        nameText.contains('course outline') ||
        body.contains('course outline');
    if (queryTokens.contains('syllabus') && !hasSyllabusEvidence) {
      return 0;
    }
    final expandedQuery = <String>{...queryTokens};
    for (final token in queryTokens) {
      for (final concept in _concepts.entries) {
        if (concept.value.contains(token)) expandedQuery.addAll(concept.value);
      }
      for (final concept in _subjectConcepts.values) {
        if (concept.contains(token)) expandedQuery.addAll(concept);
      }
    }
    final overlap = expandedQuery.where(documentTokens.contains).length;
    final typoMatch = queryTokens.isNotEmpty &&
        queryTokens.every((token) =>
            documentTokens.contains(token) ||
            documentTokens.any((word) => _oneEditApart(token, word)));
    score += math.min(220, overlap * 34);

    for (final token in queryTokens) {
      if (data.nameTokens.contains(token)) score += 34;
      if (data.bodyTokens.contains(token)) score += 11;
    }

    if (intent != null) {
      if (profile.category == intent) {
        score += (softSubjectIntent ? 320 : 650) * profile.confidence;
      } else if (softSubjectIntent) {
        // "GPU notes" describes a subject and a likely format. A relevant
        // CUDA presentation or generically classified PDF is still eligible.
      } else if (profile.category != 'document') {
        // A confident contradictory type is stronger evidence than one stray
        // matching word. This is what keeps an IRCTC ticket out of certificates.
        score -= 520 * profile.confidence;
      } else {
        // An explicit type request should not surface an unclassified file
        // solely because its generic embedding happens to be nearby.
        score -= 300;
      }
    }

    final filters = _queryFilters(q);
    for (final entry in filters.entries) {
      final expected = normalize(entry.value);
      final actual = normalize(profile.metadata[entry.key] ?? '');
      if (actual.isNotEmpty &&
          (actual.contains(expected) || expected.contains(actual))) {
        score += entry.key == 'subtype' ? 180 : 120;
      } else if (entry.key == 'subtype' && actual.isNotEmpty) {
        // Train and flight tickets share most vocabulary. A known opposite
        // subtype is therefore a hard contradiction, not a small ranking hint.
        score -= 900;
      } else if (entry.key == 'subtype') {
        score -= 520;
      } else if (actual.isNotEmpty) {
        score -= entry.key == 'date' ? 160 : 140;
      } else if (actual.isEmpty) {
        score -= entry.key == 'date' ? 140 : 100;
      }
    }

    // Neither a broad category nor an embedding establishes relevance alone.
    if (overlap == 0 &&
        !nameText.contains(q) &&
        !body.contains(q) &&
        !typoMatch) {
      return 0;
    }
    if (typoMatch && overlap == 0) score += 80;
    // The ML embedding captures related meaning when the exact words differ.
    // Keep it bounded so document type and contradictory evidence remain the
    // strongest signals for explicit searches such as "certificates".
    if (semanticSimilarity > 0.22) {
      score += ((semanticSimilarity - 0.22) * 420).clamp(0, 260);
    }

    // History is not evidence that a document answers this query.
    score -= negativeFeedback * 300;
    if (score <= 0) return 0;
    final nameTokens = data.nameTokens;
    final titleMatch =
        nameText.contains(q) || queryTokens.every(nameTokens.contains);
    final bodyMatch =
        body.contains(q) || queryTokens.every(data.bodyTokens.contains);
    final tier = titleMatch
        ? 3000
        : bodyMatch
            ? 2000
            : 1000;
    return tier + score.round().clamp(1, 999);
  }

  /// Generic file/category words must not stand in for the requested subject.
  /// Use extracted text and the filename, never inferred category or usage.
  static bool hasSubjectEvidence(String query, String name, String content) {
    final generic = <String>{
      ..._stopWords,
      for (final words in _concepts.values) ...words,
      'files',
      'documents',
      'pdf',
      'docx',
      'xlsx',
      'pptx',
      'txt',
      'note',
      'paper',
      'papers',
      'report',
      'reports',
      'project',
      'projects',
      'presentation',
      'slides',
      'spreadsheet',
      'material',
      'what',
      'where',
      'which',
      'about',
      'contains',
      'containing',
      'related',
      'everything',
      'all',
      'can',
      'you',
      'could',
      'would',
      'want',
      'need',
      'get',
      'give',
      'search',
      'looking',
      'make',
      'making',
      'faster',
      'improve',
      'improving',
      'optimize',
      'optimizing',
      'opened',
      'used',
      'worked',
      'last',
      'week',
      'today',
      'yesterday',
      'recent',
      'recently',
      'past',
      'before',
      'after',
      'around',
      'monday',
      'tuesday',
      'wednesday',
      'thursday',
      'friday',
      'saturday',
      'sunday',
    };
    final subjects = _tokens(query).where((word) =>
        !generic.contains(word) &&
        !(word.endsWith('s') &&
            generic.contains(word.substring(0, word.length - 1))) &&
        !RegExp(r'^\d+$').hasMatch(word));
    final evidence = _tokens('$name $content');
    return subjects.every((subject) {
      final accepted = <String>{subject};
      for (final concept in _subjectConcepts.values) {
        if (concept.contains(subject)) accepted.addAll(concept);
      }
      return accepted.any(evidence.contains) ||
          evidence
              .any((word) => accepted.any((term) => _oneEditApart(term, word)));
    });
  }

  static String? _queryIntent(String query) {
    if (RegExp(r'\bcourse outline\b').hasMatch(query)) {
      return 'study_material';
    }
    String? best;
    var bestScore = 0;
    for (final concept in _concepts.entries) {
      var score = 0;
      for (final word in concept.value) {
        if (query.split(' ').contains(word) ||
            query.split(' ').contains('${word}s')) {
          score++;
        }
      }
      if (score > bestScore) {
        best = concept.key;
        bestScore = score;
      }
    }
    return bestScore == 0 ? null : best;
  }

  static bool _oneEditApart(String a, String b) {
    if (a.length < 5 || b.length < 5 || (a.length - b.length).abs() > 1) {
      return false;
    }
    var i = 0, j = 0, edits = 0;
    while (i < a.length && j < b.length) {
      if (a[i] == b[j]) {
        i++;
        j++;
        continue;
      }
      if (++edits > 1) return false;
      if (a.length >= b.length) i++;
      if (b.length >= a.length) j++;
    }
    return edits + (a.length - i) + (b.length - j) <= 1;
  }

  static Map<String, String> _extractMetadata(
    String text, {
    required String category,
  }) {
    final metadata = <String, String>{};
    if (category == 'travel_ticket') {
      if (RegExp(r'\b(flight|boarding pass|air\s+ticket|airline|airport)\b')
          .hasMatch(text)) {
        metadata['subtype'] = 'flight';
      } else if (RegExp(r'\b(irctc|train|pnr|coach|berth)\b').hasMatch(text)) {
        metadata['subtype'] = 'train';
      }
      final route = RegExp(
        r'\bfrom\s+([a-z][a-z ]{1,28}?)\s+to\s+([a-z][a-z ]{1,28}?)(?=\s+(?:on|date|departure|arrival|flight|train|journey)\b|$)',
      ).firstMatch(text);
      if (route != null) {
        metadata['from'] = route.group(1)!.trim();
        metadata['to'] = route.group(2)!.trim();
      }
    }
    final date = RegExp(
      r'\b(?:\d{4}\s+\d{1,2}\s+\d{1,2}|\d{1,2}\s+\d{1,2}\s+(?:\d{2}|\d{4})|\d{1,2}\s+(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)[a-z]*\s+(?:\d{2}|\d{4}))\b',
    ).firstMatch(text);
    if (date != null) metadata['date'] = date.group(0)!;
    return metadata;
  }

  static Map<String, String> _queryFilters(String query) {
    final filters = <String, String>{};
    if (RegExp(r'\b(flight|boarding pass|airline)\b').hasMatch(query)) {
      filters['subtype'] = 'flight';
    } else if (RegExp(r'\b(train|irctc|coach|berth)\b').hasMatch(query)) {
      filters['subtype'] = 'train';
    }
    final route = RegExp(
      r'\bfrom\s+(.+?)\s+to\s+(.+?)(?=\s+(?:on|dated|booked|for)\b|$)',
    ).firstMatch(query);
    if (route != null) {
      filters['from'] = route.group(1)!.trim();
      filters['to'] = route.group(2)!.trim();
    }
    final date = RegExp(
      r'\b(?:\d{4}\s+\d{1,2}\s+\d{1,2}|\d{1,2}\s+\d{1,2}\s+(?:\d{2}|\d{4})|\d{1,2}\s+(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)[a-z]*\s+(?:\d{2}|\d{4}))\b',
    ).firstMatch(query);
    if (date != null) filters['date'] = date.group(0)!;
    return filters;
  }

  static List<String> _topKeywords(String text, {required String category}) {
    final counts = <String, int>{};
    for (final token in _tokens(text)) {
      if (token.length < 3 || _stopWords.contains(token)) continue;
      counts[token] = (counts[token] ?? 0) + 1;
    }
    final ordered = counts.entries.toList()
      ..sort((a, b) {
        final frequency = b.value.compareTo(a.value);
        return frequency != 0 ? frequency : a.key.compareTo(b.key);
      });
    return <String>{
      if (category != 'document') category,
      ...ordered.take(16).map((entry) => entry.key),
    }.take(18).toList();
  }

  static String _summary(String category, String name, List<String> keywords) {
    final label = categoryLabel(category);
    final topics =
        keywords.where((word) => word != category).take(4).join(', ');
    if (category == 'document') return name;
    return topics.isEmpty ? '$label: $name' : '$label about $topics';
  }

  static String categoryLabel(String category) => switch (category) {
        'certificate' => 'Certificate',
        'travel_ticket' => 'Travel ticket',
        'assignment' => 'Assignment',
        'invoice' => 'Invoice',
        'receipt' => 'Receipt',
        'resume' => 'Resume',
        'identity' => 'Identity document',
        'bank_statement' => 'Bank statement',
        'study_material' => 'Study material',
        'education_record' => 'Mark sheet / academic record',
        'spreadsheet' => 'Spreadsheet',
        'presentation' => 'Presentation',
        _ => 'Document',
      };

  static String normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'\bpreambur\b'), 'perambur')
      .replaceAll(RegExp(r'\b(one)\b'), '1')
      .replaceAll(RegExp(r'\b(two)\b'), '2')
      .replaceAll(RegExp(r'\b(three)\b'), '3')
      .replaceAll(RegExp(r'front[ -]?end'), 'frontend')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static Set<String> _tokens(String value) => normalize(value)
      .split(' ')
      .where((word) => word.length > 1 && !_stopWords.contains(word))
      .toSet();
}
