import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_search_app/core/platform/search_platform.dart';
import 'package:smart_search_app/core/storage/preference_keys.dart';
import 'package:smart_search_app/design_system/nexa_surfaces.dart';
import 'package:smart_search_app/design_system/nexa_theme.dart';
import 'package:smart_search_app/features/account/data/account_sync.dart';
import 'package:smart_search_app/features/cloud_index/data/cloud_index_api.dart';
import 'package:smart_search_app/features/cloud_index/data/cloud_index_repository.dart';
import 'package:smart_search_app/features/cloud_index/domain/cloud_index_models.dart';
import 'package:smart_search_app/features/commands/domain/universal_action.dart';
import 'package:smart_search_app/features/contacts/domain/indexed_contact.dart';
import 'package:smart_search_app/features/documents/data/document_search_service.dart';
import 'package:smart_search_app/features/documents/data/native_document_mapper.dart';
import 'package:smart_search_app/features/documents/domain/document_intelligence.dart';
import 'package:smart_search_app/features/documents/domain/indexed_document.dart';
import 'package:smart_search_app/features/documents/domain/indexing_schedule.dart';
import 'package:smart_search_app/features/history/data/history_entry_codec.dart';
import 'package:smart_search_app/features/knowledge/domain/knowledge_answer.dart';
import 'package:smart_search_app/features/search/models/search_result.dart';
import 'package:smart_search_app/features/search/presentation/widgets/conversation_cards.dart';
import 'package:smart_search_app/features/search/presentation/widgets/search_controls.dart';
import 'package:smart_search_app/features/search/presentation/widgets/search_result_card.dart';
import 'package:smart_search_app/features/search/presentation/widgets/search_status_banners.dart';
import 'package:smart_search_app/features/settings/presentation/settings_screen.dart';
import 'package:smart_search_app/features/voice/domain/voice_session.dart';
import 'package:smart_search_app/features/web/presentation/web_search_browser.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';

/// Commands available to the app shell without exposing private widget state.
///
/// One controller belongs to one mounted [SearchScreen]. Commands are no-ops
/// while that screen is absent (for example, during account onboarding).
class SearchScreenController {
  Future<void> Function()? _clearHistory;
  Future<void> Function(SearchResult)? _openResult;

  Future<void> clearHistory() => _clearHistory?.call() ?? Future<void>.value();

  Future<void> openResult(SearchResult result) =>
      _openResult?.call(result) ?? Future<void>.value();

  void _attach({
    required Future<void> Function() clearHistory,
    required Future<void> Function(SearchResult) openResult,
  }) {
    _clearHistory = clearHistory;
    _openResult = openResult;
  }

  void _detach() {
    _clearHistory = null;
    _openResult = null;
  }
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({
    required this.isDarkMode,
    required this.themeMode,
    required this.onSetThemeMode,
    required this.accountSync,
    required this.onSignedIn,
    required this.onOpenHistory,
    required this.onHistoryChanged,
    this.controller,
    this.onAskAi,
    this.onGeminiSettings,
    super.key,
  });

  final SearchScreenController? controller;
  final ValueChanged<String>? onAskAi;
  final VoidCallback? onGeminiSettings;
  final bool isDarkMode;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onSetThemeMode;
  final AccountSync? accountSync;
  final Future<void> Function() onSignedIn;
  final VoidCallback onOpenHistory;
  final ValueChanged<List<SearchResult>> onHistoryChanged;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final SpeechToText _speechToText = SpeechToText();
  late final AnimationController _voicePulseController;
  Future<bool>? _speechInitialization;
  bool _speechReady = false;
  bool _startupEffectsReady = false;
  Timer? _startupAppsTimer;
  Timer? _startupDocumentsTimer;

  final List<Map<String, String>> _apps = [];
  final List<IndexedDocument> _documents = [];
  final List<IndexedContact> _contacts = [];
  final Map<String, String> _resultArtwork = {};
  final Set<String> _resultArtworkRequests = {};
  final Map<String, int> _documentFeedback = {};
  final Map<String, String> _contactAliases = {};
  final Map<String, int> _contactSelectionCounts = {};
  final Map<String, DateTime> _contactLastSelected = {};
  final Map<String, int> _systemCallCounts = {};
  final Map<String, DateTime> _systemLastCalled = {};
  List<SearchResult> _history = [];
  List<KnowledgeConversationTurn> _conversationTurns = [];
  String? _activeConversationTurnId;

  List<SearchResult> _results = [];
  List<MapEntry<IndexedDocument, int>> _rankedDocuments = [];
  final Map<String, String> _documentExcerpts = {};
  String? _rankedDocumentQuery;
  String? _rankingRequestKey;
  bool _rankingBusy = false;
  final _documentSearchService = DocumentSearchService();
  late final CloudIndexRepository _cloudIndexRepository;
  List<SearchResult> _cloudDocumentResults = const [];
  String? _cloudDocumentQuery;
  bool _cloudSearchInFlight = false;
  bool _cloudSearchOffline = false;
  final _resultsScrollController = ScrollController();
  String? _readingResultsQuery;
  List<SearchResult>? _deferredResults;
  final _preparedDocumentRows = Expando<Map<String, dynamic>>();
  Map<String, dynamic>? _queuedRanking;
  bool _loadingContacts = true;
  bool _loadingApps = true;
  bool _loadingDocuments = true;
  bool _documentIndexing = false;
  bool _requestedAllFilesAccess = false;
  bool _awaitingRestartAfterFileAccess = false;
  bool _documentsLoaded = false;
  bool _documentLoadInFlight = false;
  bool _nativeDocumentSearchInFlight = false;
  int _nativeDocumentSearchGeneration = 0;
  String? _nativeDocumentSearchQuery;
  String? _nativeDocumentSearchCompleteQuery;
  DateTime? _nativeDocumentSearchAt;
  final Map<String, IndexedDocument> _nativeDocumentMatches = {};
  bool _contactsPermissionDenied = false;
  bool _isListening = false;
  bool _voiceConversationActive = false;
  VoiceSessionPhase _voicePhase = VoiceSessionPhase.idle;
  final VoiceConversationContext _voiceContext = VoiceConversationContext();
  bool _voiceCommandHandled = false;
  bool _voiceFollowUpMode = false;
  bool _voiceStopRequested = false;
  bool _voiceResumePending = false;
  // A document viewer temporarily backgrounds Apex. Keep this one search
  // session intact so a user can return and open another matching file.
  bool _preserveSearchOnNextResume = false;
  bool _continuousVoice = true;
  bool _requireWakePhrase = false;
  bool _spokenResponses = true;
  int _voiceListenGeneration = 0;
  int _voicePromptGeneration = 0;
  int _voiceSilentRestarts = 0;
  DateTime? _voiceFollowUpDeadline;
  Timer? _voiceRestartTimer;
  Timer? _voiceFollowUpTimer;
  StructuredCommand? _pendingVoiceConfirmation;
  StructuredCommand? _voiceCommandBeforeConfirmation;
  String? _lastVoiceCommandText;
  String _voiceStatusMessage = 'Say what you need';
  bool _appIsResumed = true;
  String _voiceTranscript = '';
  double _voiceTranscriptConfidence = -1;
  DateTime? _voiceListeningStartedAt;
  double _voiceLevel = 0;
  double _minimumVoiceLevel = double.infinity;
  double _maximumVoiceLevel = double.negativeInfinity;
  String _query = '';
  bool _composerHasText = false;
  String? _quickSearchHint;
  String _contextScope = 'Contacts, apps & files';
  String _resultFilter = 'All';
  UniversalIntent _activeIntent = const UniversalIntent(
    type: UniversalIntentType.unknown,
    rawText: '',
  );
  StructuredCommand _activeCommand = const StructuredCommand(
    intent: UniversalIntent(
      type: UniversalIntentType.unknown,
      rawText: '',
    ),
    source: CommandUnderstandingSource.deterministic,
    confidence: 0,
    requiresConfirmation: false,
  );
  List<ContactMatch> _activeContactMatches = const <ContactMatch>[];
  UniversalIntent? _pendingContactIntent;
  List<ContactMatch> _pendingContactMatches = const <ContactMatch>[];
  bool _contactChosenByFollowUp = false;
  List<int>? _semanticQueryEmbedding;
  String? _voiceUndoQuery;
  List<SearchResult>? _voiceUndoResults;
  StructuredCommand? _voiceUndoCommand;
  UniversalIntent? _voiceUndoIntent;
  String? _semanticQueryText;
  String? _semanticRequestText;
  Timer? _debounceTimer;
  Timer? _fileSearchDebounceTimer;
  Timer? _focusTimer;
  Timer? _semanticDebounceTimer;
  Timer? _documentIndexPollTimer;
  Timer? _documentIndexResumeTimer;
  bool _documentIndexPausedForSearch = false;
  bool _importPromptOpen = false;
  int _documentIndexRevision = 0;
  String? _documentIndexState;
  int _documentIndexedFiles = 0;
  int _documentTotalFiles = 0;
  String _documentIndexCurrentFile = '';
  String _documentIndexLastError = '';
  String _documentIndexMode = 'balanced';
  int _documentIndexScheduleStartMinute = 0;
  int _documentIndexScheduleEndMinute = 7 * 60;

  static const List<IndexedDocument> _starterDocuments = [
    IndexedDocument(name: 'Project proposal.pdf', type: 'PDF'),
    IndexedDocument(name: 'College notes.docx', type: 'Document'),
    IndexedDocument(name: 'Payment receipt.xlsx', type: 'Spreadsheet'),
    IndexedDocument(name: 'Presentation draft.pptx', type: 'Slides'),
  ];

  @override
  void initState() {
    super.initState();
    _cloudIndexRepository = CloudIndexRepository(
      api: CloudIndexApi(
        tokenProvider: () async => widget.accountSync?.getIdToken(),
      ),
    );
    _attachController();
    WidgetsBinding.instance.addObserver(this);
    _voicePulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );

    _controller.clear();
    _query = '';
    _results = [];

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // A post-frame callback only means painting commands were submitted.
      // Wait for the raster thread before starting plugins, IO, or glass effects.
      await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
      if (!mounted) return;
      setState(() => _startupEffectsReady = true);
      // This one-time vector migration is explicitly behind the first
      // rasterized frame. It never delays the usable search shell.
      unawaited(_prepareSemanticSearchStorage());
      unawaited(_loadSources());
      unawaited(_loadDocumentFeedback());
      unawaited(_loadContactLearning());
      unawaited(_loadVoicePreferences());
      unawaited(_loadDocumentIndexMode());
      unawaited(_loadDocumentIndexSchedule());
      unawaited(_loadKnowledgeConversation());
      unawaited(_clearRemovedGroupData());
      unawaited(_setDocumentIndexPausedForSearch(false, force: true));
      searchPlatformChannel.setMethodCallHandler((call) async {
        if (call.method == 'sharedDocumentsAvailable') {
          unawaited(_promptForSharedDocuments());
        }
      });
      unawaited(_promptForSharedDocuments());
    });
  }

  void _attachController() {
    widget.controller?._attach(
      clearHistory: _clearAllHistory,
      openResult: _openResult,
    );
  }

  @override
  void didUpdateWidget(covariant SearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach();
      _attachController();
    }
  }

  @override
  void dispose() {
    searchPlatformChannel.setMethodCallHandler(null);
    widget.controller?._detach();
    _startupAppsTimer?.cancel();
    _documentSearchService.dispose();
    _resultsScrollController.dispose();
    _startupDocumentsTimer?.cancel();
    _debounceTimer?.cancel();
    _fileSearchDebounceTimer?.cancel();
    _focusTimer?.cancel();
    _semanticDebounceTimer?.cancel();
    _documentIndexPollTimer?.cancel();
    _documentIndexResumeTimer?.cancel();
    _voiceRestartTimer?.cancel();
    _voiceFollowUpTimer?.cancel();
    unawaited(_speechToText.cancel());
    unawaited(_stopVoicePrompt());
    _voicePulseController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appIsResumed = state == AppLifecycleState.resumed;
    if (!_appIsResumed && _voiceConversationActive) {
      _voiceResumePending = !_voiceStopRequested;
      _voiceRestartTimer?.cancel();
      unawaited(_speechToText.cancel());
      if (mounted) {
        setState(() {
          _isListening = false;
          _voicePhase = VoiceSessionPhase.awaitingFollowUp;
        });
      }
    }
    if (state == AppLifecycleState.resumed) {
      if (_startupEffectsReady) unawaited(_promptForSharedDocuments());
      if (_awaitingRestartAfterFileAccess) {
        _awaitingRestartAfterFileAccess = false;
        // The user may have declined access, so allow another explicit restart
        // attempt. Android performs the requested restart from its onResume.
        _requestedAllFilesAccess = false;
        Timer(const Duration(milliseconds: 400), () {
          if (mounted) _monitorDocumentIndexing();
        });
      }
      final preserveSearch = _preserveSearchOnNextResume;
      _preserveSearchOnNextResume = false;
      if (!_voiceResumePending && !preserveSearch) {
        setState(() {
          _controller.clear();
          _query = '';
          _results = [];
        });
      }
      unawaited(_loadHistory());
      // Re-enumerating document rows would refresh and reorder the cards the
      // user was reading. A normal resume still refreshes as before.
      unawaited(_loadDocuments(
        force: !preserveSearch,
        startIndexing: !preserveSearch,
      ));
      unawaited(_setDocumentIndexPausedForSearch(false, force: true));
      if (_voiceResumePending && !_voiceStopRequested) {
        _voiceResumePending = false;
        unawaited(_beginVoiceFollowUp(
          prompt: 'You can correct that or ask for the next thing.',
        ));
      }
    }
  }

  void _requestFocus() {
    if (!mounted) return;
    _focusTimer?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _startQuickSearch(String hint) {
    setState(() => _quickSearchHint = hint);
    _requestFocus();
  }

  /// Keeps lightweight app/contact matching responsive while the user types.
  /// File-content and semantic matching run only after the input settles.
  void _handleQueryInput(String rawValue) {
    final query = rawValue.trim();
    if (query != _query) {
      // Invalidate native work immediately on the keystroke. The settled query
      // receives a newer request id, so stale exact-vector scans cannot block
      // or publish over the latest text.
      unawaited(_cancelNativeDocumentSearch());
      _readingResultsQuery = null;
      _deferredResults = null;
      if (_resultsScrollController.hasClients &&
          _resultsScrollController.offset != 0) {
        _resultsScrollController.jumpTo(0);
      }
    }
    _debounceTimer?.cancel();
    _fileSearchDebounceTimer?.cancel();
    _documentIndexResumeTimer?.cancel();
    _semanticDebounceTimer?.cancel();
    _semanticRequestText = null;
    _queuedRanking = null;
    _rankingRequestKey = null;

    // Updating the whole results page for every character forces Flutter to
    // rebuild every visible card. Only rebuild immediately when the composer
    // changes between its empty and non-empty states; the debounced search
    // below publishes the actual query and results.
    _query = query;
    final composerStateChanged = _composerHasText != query.isNotEmpty;
    if (composerStateChanged) {
      setState(() => _composerHasText = query.isNotEmpty);
    }
    if (query.isEmpty) {
      _refreshResults('', includeDocumentSearch: false);
      unawaited(_setDocumentIndexPausedForSearch(false));
      return;
    }

    // Avoid competing with OCR/PDF indexing while the user is interacting.
    unawaited(_setDocumentIndexPausedForSearch(true));

    _debounceTimer = Timer(const Duration(milliseconds: 120), () {
      if (mounted && _query == query) {
        _refreshResults(query, includeDocumentSearch: false);
      }
    });
    _fileSearchDebounceTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || _query != query) return;
      _refreshResults(query);
      _documentIndexResumeTimer = Timer(const Duration(seconds: 2), () {
        if (mounted && _query == query) {
          unawaited(_setDocumentIndexPausedForSearch(false));
        }
      });
    });
  }

  Future<void> _setDocumentIndexPausedForSearch(
    bool paused, {
    bool force = false,
  }) async {
    if (!force && _documentIndexPausedForSearch == paused) return;
    _documentIndexPausedForSearch = paused;
    try {
      await searchPlatformChannel.invokeMethod<bool>(
        'setDocumentIndexPaused',
        {'paused': paused},
      );
    } catch (_) {
      // Indexing is optional; search must remain usable if the platform call
      // is unavailable (for example in a widget test or on desktop).
    }
  }

  Future<void> _loadKnowledgeConversation() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final encoded = preferences.getString(PreferenceKeys.localConversation);
      if (encoded == null || encoded.isEmpty || !mounted) return;
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return;
      final turns = decoded
          .whereType<Map>()
          .map((item) => KnowledgeConversationTurn.fromJson(
              Map<String, dynamic>.from(item)))
          .where((turn) => turn.query.isNotEmpty)
          .toList();
      if (mounted) setState(() => _conversationTurns = turns.take(30).toList());
    } catch (_) {
      // Corrupt or unavailable conversation state starts cleanly.
    }
  }

  Future<void> _saveKnowledgeConversation() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        PreferenceKeys.localConversation,
        jsonEncode(_conversationTurns.map((turn) => turn.toJson()).toList()),
      );
    } catch (_) {
      // Conversation persistence is optional; the active answer remains usable.
    }
  }

  void _commitConversationQuery(String query) {
    final value = query.trim();
    if (value.isEmpty) return;
    final latest = _conversationTurns.isEmpty ? null : _conversationTurns.last;
    if (latest?.query == value && latest?.id == _activeConversationTurnId) {
      return;
    }
    final now = DateTime.now();
    final turn = KnowledgeConversationTurn(
      id: now.microsecondsSinceEpoch.toString(),
      query: value,
      createdAt: now,
    );
    setState(() {
      _conversationTurns = [..._conversationTurns, turn]
          .skip(math.max(0, _conversationTurns.length + 1 - 30))
          .toList();
      _activeConversationTurnId = turn.id;
    });
    unawaited(_saveKnowledgeConversation());
  }

  KnowledgeAnswer? _composeKnowledgeAnswer(String query) {
    if (_rankedDocumentQuery != query) return null;
    return KnowledgeAnswerComposer.compose(
      query,
      _rankedDocuments.take(5).map((match) {
        final document = match.key;
        return KnowledgeEvidence(
          title: document.name,
          summary: document.summary,
          excerpt: _documentExcerpts[document.path ?? document.name] ?? '',
          category: document.category,
          folder: document.folder,
          reasons: document.graphReasons,
        );
      }).toList(),
    );
  }

  void _updateConversationAnswer(String query) {
    final answer = _composeKnowledgeAnswer(query);
    final id = _activeConversationTurnId;
    if (answer == null || id == null) return;
    final index = _conversationTurns.indexWhere((turn) => turn.id == id);
    if (index < 0) return;
    setState(() {
      final updated = [..._conversationTurns];
      updated[index] = updated[index].withAnswer(answer);
      _conversationTurns = updated;
    });
    unawaited(_saveKnowledgeConversation());
  }

  String _resolveKnowledgeQuery(String query) {
    final value = query.trim();
    final needsContext = RegExp(
      r'\b(this|that|these|those|it|them|related files?|same project)\b',
      caseSensitive: false,
    ).hasMatch(value);
    if (!needsContext) return value;
    for (final turn in _conversationTurns.reversed) {
      if (turn.query.trim().isNotEmpty && turn.query.trim() != value) {
        return '$value ${turn.query.trim()}';
      }
    }
    return value;
  }

  Future<void> _loadDocumentIndexMode() async {
    try {
      final mode = await searchPlatformChannel
          .invokeMethod<String>('getDocumentIndexMode');
      if (!mounted || mode == null) return;
      setState(() => _documentIndexMode = mode);
    } catch (_) {
      // Native indexing settings are unavailable in desktop/widget tests.
    }
  }

  Future<void> _loadDocumentIndexSchedule() async {
    try {
      final schedule =
          await searchPlatformChannel.invokeMethod<Map<dynamic, dynamic>>(
        'getDocumentIndexSchedule',
      );
      if (!mounted || schedule == null) return;
      final startMinute = int.tryParse('${schedule['startMinute'] ?? 0}') ?? 0;
      final endMinute =
          int.tryParse('${schedule['endMinute'] ?? 7 * 60}') ?? 7 * 60;
      setState(() {
        _documentIndexScheduleStartMinute = startMinute.clamp(0, 1439).toInt();
        _documentIndexScheduleEndMinute = endMinute.clamp(0, 1439).toInt();
      });
    } catch (_) {
      // Native indexing settings are unavailable in desktop/widget tests.
    }
  }

  Future<bool> _setDocumentIndexMode(String mode) async {
    try {
      final saved = await searchPlatformChannel.invokeMethod<bool>(
        'setDocumentIndexMode',
        {'mode': mode},
      );
      if (saved != true) {
        if (mounted) _showMessage('Could not update the indexing mode.');
        return false;
      }
      if (mounted) setState(() => _documentIndexMode = mode);
      _monitorDocumentIndexing();
      return true;
    } catch (_) {
      if (mounted) _showMessage('Could not update the indexing mode.');
      return false;
    }
  }

  Future<bool> _setDocumentIndexSchedule({
    required int startMinute,
    required int endMinute,
  }) async {
    try {
      final saved = await searchPlatformChannel.invokeMethod<bool>(
        'setDocumentIndexSchedule',
        {
          'startMinute': startMinute,
          'endMinute': endMinute,
        },
      );
      if (saved != true) {
        if (mounted) _showMessage('Could not update the scan schedule.');
        return false;
      }
      if (mounted) {
        setState(() {
          _documentIndexScheduleStartMinute =
              startMinute.clamp(0, 1439).toInt();
          _documentIndexScheduleEndMinute = endMinute.clamp(0, 1439).toInt();
        });
      }
      _monitorDocumentIndexing();
      return true;
    } catch (_) {
      if (mounted) _showMessage('Could not update the scan schedule.');
      return false;
    }
  }

  Future<bool> _restartDocumentIndexing() async {
    try {
      final restarted = await searchPlatformChannel.invokeMethod<bool>(
        'restartDocumentIndexing',
      );
      if (restarted != true) {
        if (mounted) _showMessage('Could not restart the file scan.');
        return false;
      }
      if (mounted) {
        setState(() {
          _documentIndexState = 'queued';
          _documentIndexedFiles = 0;
          _documentTotalFiles = 0;
          _documentIndexCurrentFile = '';
          _documentIndexLastError = '';
        });
      }
      _monitorDocumentIndexing();
      return true;
    } on PlatformException catch (error) {
      if (error.code == 'FILES_PERMISSION_REQUIRED') {
        _showMessage(
          'Enable “All files access” to scan your phone from the beginning.',
        );
        if (!_requestedAllFilesAccess) {
          _requestedAllFilesAccess = true;
          _awaitingRestartAfterFileAccess = true;
          try {
            final opened = await searchPlatformChannel.invokeMethod<bool>(
              'requestAllFilesAccess',
              {'forceRecovery': true, 'restart': true},
            );
            if (opened != true) {
              _awaitingRestartAfterFileAccess = false;
              _requestedAllFilesAccess = false;
            }
          } catch (_) {
            _awaitingRestartAfterFileAccess = false;
            _requestedAllFilesAccess = false;
            if (mounted) _showMessage('Could not open file access settings.');
          }
        }
        return false;
      }
      if (mounted) _showMessage('Could not restart the file scan.');
      return false;
    } catch (_) {
      if (mounted) _showMessage('Could not restart the file scan.');
      return false;
    }
  }

  String get _documentIndexModeLabel => switch (_documentIndexMode) {
        'ultra_fast' => 'Ultra fast',
        'fast' => 'Fast',
        'slow' => 'Slow',
        _ => 'Balanced',
      };

  String get _documentIndexScheduleLabel => formatIndexingWindow(
        _documentIndexScheduleStartMinute,
        _documentIndexScheduleEndMinute,
      );

  Future<void> _clearRemovedGroupData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(PreferenceKeys.legacyManualGroups);
    await prefs.remove(PreferenceKeys.legacyManualGroupLinks);
  }

  Future<void> _loadVoicePreferences() async {
    final preferences = await SharedPreferences.getInstance();
    _continuousVoice =
        preferences.getBool(PreferenceKeys.continuousVoice) ?? true;
    _requireWakePhrase =
        preferences.getBool(PreferenceKeys.requireWakePhrase) ?? false;
    _spokenResponses =
        preferences.getBool(PreferenceKeys.spokenResponses) ?? true;
  }

  void _setVoiceState(
    VoiceSessionPhase phase, {
    String? status,
  }) {
    if (!mounted) return;
    final active =
        phase != VoiceSessionPhase.idle && phase != VoiceSessionPhase.error;
    final listening = phase == VoiceSessionPhase.listening;
    if (listening && !_voicePulseController.isAnimating) {
      _voicePulseController.repeat();
    } else if (!listening && _voicePulseController.isAnimating) {
      _voicePulseController
        ..stop()
        ..reset();
    }
    setState(() {
      _voicePhase = phase;
      _voiceConversationActive = active;
      _isListening = listening;
      if (status != null) _voiceStatusMessage = status;
      if (!active) _voiceLevel = 0;
    });
  }

  Future<bool> _ensureSpeechInitialized() {
    if (_speechReady) return Future<bool>.value(true);
    return _speechInitialization ??= _initializeSpeech();
  }

  Future<bool> _initializeSpeech() async {
    final available = await _speechToText.initialize(
      onStatus: (status) {
        if (!mounted || (status != 'done' && status != 'notListening')) return;
        unawaited(_handleSpeechStopped(_voiceListenGeneration));
      },
      onError: (error) {
        unawaited(_handleSpeechError(error, _voiceListenGeneration));
      },
      options: <SpeechConfigOption>[SpeechToText.androidNoBluetooth],
    );
    _speechReady = available;
    if (!available) _speechInitialization = null;
    return available;
  }

  Future<void> _handleSpeechError(
    SpeechRecognitionError error,
    int generation,
  ) async {
    if (!mounted || generation != _voiceListenGeneration) return;
    if ((error.errorMsg == 'error_no_match' ||
            error.errorMsg == 'error_speech_timeout') &&
        _voiceTranscript.isNotEmpty &&
        !_voiceCommandHandled) {
      await _finishVoiceCommand(generation);
      return;
    }
    if (!_voiceStopRequested &&
        _voiceFollowUpMode &&
        (error.errorMsg == 'error_no_match' ||
            error.errorMsg == 'error_speech_timeout' ||
            error.errorMsg == 'error_busy' ||
            error.errorMsg == 'error_client') &&
        _canContinueVoiceFollowUp) {
      _scheduleVoiceRestart();
      return;
    }
    _setVoiceState(VoiceSessionPhase.error, status: 'Voice paused');
    _voiceStopRequested = true;
    _voiceResumePending = false;
    _voiceRestartTimer?.cancel();
    _voiceFollowUpTimer?.cancel();
    _voiceFollowUpDeadline = null;
    _voiceFollowUpMode = false;
    _pendingVoiceConfirmation = null;
    _voiceContext.restore(_voiceCommandBeforeConfirmation);
    _voiceCommandBeforeConfirmation = null;
    _voicePromptGeneration++;
    final hasMicrophonePermission = await _speechToText.hasPermission;
    if (!mounted) return;
    debugPrint('Speech recognition error: ${error.errorMsg}');

    final message = switch (error.errorMsg) {
      'error_permission' when !hasMicrophonePermission =>
        'Microphone permission is off. Allow it in Android Settings and try again.',
      'error_permission' =>
        'Android speech recognition could not access the microphone. Close other voice apps and try again.',
      'error_busy' ||
      'error_client' =>
        'The Android speech service is busy. Wait a moment and try again.',
      'error_network' ||
      'error_network_timeout' =>
        'Speech recognition needs a working internet connection on this device.',
      'error_language_not_supported' ||
      'error_language_unavailable' =>
        'Your phone does not have speech recognition for the current language.',
      'error_no_match' ||
      'error_speech_timeout' =>
        'I did not catch that. Tap the microphone and try again.',
      'error_audio_error' =>
        'The microphone is being used by another app. Close it and try again.',
      _ => 'Voice search stopped. Please try again.',
    };
    _showMessage(message);
    unawaited(_speakVoicePrompt(message));
  }

  Future<void> _handleSpeechStopped(int generation) async {
    if (!mounted ||
        generation != _voiceListenGeneration ||
        _voiceStopRequested) {
      return;
    }
    final startedAt = _voiceListeningStartedAt;
    if (_isListening &&
        _voiceTranscript.isEmpty &&
        startedAt != null &&
        DateTime.now().difference(startedAt) <
            const Duration(milliseconds: 700)) {
      // A delayed "done" from the previous recognition session can arrive
      // just after the contact follow-up microphone has reopened.
      return;
    }
    if (_voiceCommandHandled) return;
    // Some Android recognizers send several useful partial results and then
    // stop without flagging the final callback. Preserve that speech instead
    // of silently throwing away the user's last words.
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted ||
        generation != _voiceListenGeneration ||
        _voiceCommandHandled ||
        _voiceStopRequested) {
      return;
    }
    if (_voiceTranscript.isNotEmpty) {
      await _finishVoiceCommand(generation);
    } else if (_voiceFollowUpMode && _canContinueVoiceFollowUp) {
      _scheduleVoiceRestart();
    } else {
      await _endVoiceConversation(
        message: _voiceFollowUpMode
            ? null
            : 'I did not hear anything. Tap the microphone when you are ready.',
      );
    }
  }

  Future<void> _finishVoiceCommand(int generation) async {
    if (_voiceCommandHandled ||
        _voiceStopRequested ||
        generation != _voiceListenGeneration) {
      return;
    }
    final assessment = VoiceTranscriptGate.assess(
      _voiceTranscript,
      confidence: _voiceTranscriptConfidence,
      requireWakePhrase: _requireWakePhrase,
      responseWasRequested: _voiceFollowUpMode,
    );
    _voiceCommandHandled = true;
    if (!assessment.accepted) {
      final message = switch (assessment.rejection) {
        VoiceTranscriptRejection.missingWakePhrase =>
          'Say “Apex AI” before your request so I know it is meant for me.',
        VoiceTranscriptRejection.probableNoise =>
          'I heard mostly background noise. Please say that once more.',
        VoiceTranscriptRejection.empty ||
        VoiceTranscriptRejection.tooShort =>
          'I did not catch a complete request. Please try once more.',
        VoiceTranscriptRejection.none => '',
      };
      _showMessage(message);
      if (_voiceFollowUpMode && _canContinueVoiceFollowUp) {
        await _beginVoiceFollowUp(prompt: message, keepDeadline: true);
      } else {
        await _endVoiceConversation();
      }
      return;
    }
    _setVoiceState(
      VoiceSessionPhase.processing,
      status: 'Understanding…',
    );
    await _handleVoiceWords(assessment.text);
  }

  void _updateVoiceLevel(double level) {
    if (!mounted || !_voiceConversationActive) return;
    _minimumVoiceLevel = math.min(_minimumVoiceLevel, level);
    _maximumVoiceLevel = math.max(_maximumVoiceLevel, level);
    final range = _maximumVoiceLevel - _minimumVoiceLevel;
    final normalized =
        range < 0.5 ? 0.25 : ((level - _minimumVoiceLevel) / range).clamp(0, 1);
    if ((normalized - _voiceLevel).abs() >= 0.04) {
      setState(() => _voiceLevel = normalized.toDouble());
    }
  }

  bool get _canContinueVoiceFollowUp =>
      _voiceFollowUpDeadline != null &&
      DateTime.now().isBefore(_voiceFollowUpDeadline!) &&
      _voiceSilentRestarts < 3;

  Future<void> _startVoiceListening({
    bool followUp = false,
    bool keepDeadline = false,
  }) async {
    if (_voiceStopRequested || !_appIsResumed) {
      _voiceResumePending = !_voiceStopRequested;
      return;
    }
    final available = await _ensureSpeechInitialized();
    if (!available) {
      _showMessage(
          'Voice search is unavailable. Check microphone and speech recognition permissions.');
      return;
    }

    // A final result can arrive before the platform's `notListening` status.
    // Close that recognizer before opening the next turn so its pause timer
    // and late callbacks cannot overlap the follow-up session.
    // A recognizer can report notListening while its Dart pause timer remains
    // armed. Always close the previous turn before creating another timer.
    try {
      await _speechToText.cancel();
    } catch (_) {}
    await _stopVoicePrompt();
    if (!mounted || _voiceStopRequested || !_appIsResumed) return;
    final generation = ++_voiceListenGeneration;
    _voiceCommandHandled = false;
    _voiceTranscript = '';
    _voiceTranscriptConfidence = -1;
    _voiceListeningStartedAt = DateTime.now();
    _minimumVoiceLevel = double.infinity;
    _maximumVoiceLevel = double.negativeInfinity;
    _voiceFollowUpMode = followUp;
    if (!followUp || !keepDeadline || _voiceFollowUpDeadline == null) {
      _voiceFollowUpDeadline =
          followUp ? DateTime.now().add(const Duration(seconds: 18)) : null;
      _voiceSilentRestarts = 0;
    }
    _setVoiceState(
      VoiceSessionPhase.listening,
      status: followUp
          ? (_pendingVoiceConfirmation == null
              ? 'Listening for a correction or follow-up…'
              : _voiceStatusMessage)
          : (_requireWakePhrase
              ? 'Say “Apex AI”, then your request'
              : 'Listening…'),
    );
    try {
      await _speechToText.listen(
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          listenMode: _pendingVoiceConfirmation == null
              ? ListenMode.dictation
              : ListenMode.confirmation,
          pauseFor:
              Duration(seconds: _pendingVoiceConfirmation == null ? 3 : 2),
          listenFor: followUp
              ? const Duration(seconds: 12)
              : const Duration(seconds: 45),
        ),
        onSoundLevelChange: _updateVoiceLevel,
        onResult: (result) {
          if (!mounted ||
              generation != _voiceListenGeneration ||
              _voiceStopRequested) {
            return;
          }
          final words =
              SpokenCommandNlp.normalizeTranscript(result.recognizedWords);
          if (words.isEmpty) return;
          // Prefer the longest stable hypothesis. A late, noisy callback can
          // otherwise replace a complete sentence with only its last word.
          if (words.length >= _voiceTranscript.length || result.finalResult) {
            _voiceTranscript = words;
            _voiceTranscriptConfidence =
                result.confidence > 0 ? result.confidence : -1;
          }
          _controller.value = TextEditingValue(
            text: _voiceTranscript,
            selection: TextSelection.collapsed(offset: _voiceTranscript.length),
          );
          setState(() => _query = _voiceTranscript);
          if (result.finalResult) {
            unawaited(_finishVoiceCommand(generation));
          } else {
            _refreshResults(_voiceTranscript, includeDocumentSearch: false);
          }
        },
      );
    } catch (_) {
      if (!mounted || generation != _voiceListenGeneration) return;
      if (followUp && _canContinueVoiceFollowUp) {
        _scheduleVoiceRestart();
      } else {
        _setVoiceState(VoiceSessionPhase.error, status: 'Voice unavailable');
        _showMessage('Voice search could not start. Please try again.');
      }
    }
  }

  void _scheduleVoiceRestart() {
    if (_voiceStopRequested || !_canContinueVoiceFollowUp) {
      unawaited(_endVoiceConversation());
      return;
    }
    _voiceSilentRestarts++;
    _setVoiceState(
      VoiceSessionPhase.awaitingFollowUp,
      status: 'Still here — you can continue speaking',
    );
    _voiceRestartTimer?.cancel();
    _voiceRestartTimer = Timer(const Duration(milliseconds: 550), () {
      if (mounted && !_voiceStopRequested) {
        unawaited(_startVoiceListening(followUp: true, keepDeadline: true));
      }
    });
  }

  Future<void> _beginVoiceFollowUp({
    String prompt = 'You can correct that or ask for the next thing.',
    bool keepDeadline = false,
  }) async {
    if (!mounted || _voiceStopRequested) return;
    await _loadVoicePreferences();
    if (!_continuousVoice) {
      await _endVoiceConversation();
      return;
    }
    _voiceFollowUpMode = true;
    if (!keepDeadline || _voiceFollowUpDeadline == null) {
      _voiceFollowUpDeadline = DateTime.now().add(const Duration(seconds: 18));
      _voiceSilentRestarts = 0;
    }
    _setVoiceState(
      _pendingVoiceConfirmation == null
          ? VoiceSessionPhase.awaitingFollowUp
          : VoiceSessionPhase.confirming,
      status: prompt,
    );
    _voiceFollowUpTimer?.cancel();
    final remaining = _voiceFollowUpDeadline!.difference(DateTime.now());
    _voiceFollowUpTimer = Timer(remaining + const Duration(milliseconds: 250),
        () => unawaited(_endVoiceConversation()));
    if (!_appIsResumed) {
      _voiceResumePending = true;
      return;
    }
    final promptGeneration = ++_voicePromptGeneration;
    await _speakVoicePrompt(prompt);
    if (!mounted ||
        _voiceStopRequested ||
        promptGeneration != _voicePromptGeneration) {
      return;
    }
    await _startVoiceListening(followUp: true, keepDeadline: true);
  }

  Future<void> _handleVoiceWords(String words) async {
    final resolution = _voiceContext.resolve(
      words,
      resultCount: _results.length,
      awaitingConfirmation: _pendingVoiceConfirmation != null,
    );
    switch (resolution.kind) {
      case VoiceFollowUpKind.stop:
        await _endVoiceConversation(message: 'Voice conversation ended.');
        return;
      case VoiceFollowUpKind.cancel:
        _pendingVoiceConfirmation = null;
        _voiceContext.restore(_voiceCommandBeforeConfirmation);
        _voiceCommandBeforeConfirmation = null;
        await _beginVoiceFollowUp(
            prompt: 'Cancelled. What should I do instead?');
        return;
      case VoiceFollowUpKind.confirm:
        final pending = _pendingVoiceConfirmation;
        if (pending == null) {
          await _beginVoiceFollowUp(
              prompt: 'There is nothing waiting for confirmation.');
          return;
        }
        _pendingVoiceConfirmation = null;
        _voiceCommandBeforeConfirmation = null;
        await _executeVoiceCommand(
          VoiceConversationContext.commandTextFor(pending.intent),
          skipConfirmation: true,
        );
        return;
      case VoiceFollowUpKind.selectResult:
        final index = resolution.resultIndex!;
        if (index >= _results.length) {
          await _beginVoiceFollowUp(
              prompt: 'That result is no longer available. Choose another.');
          return;
        }
        await _openResult(_results[index]);
        await _beginVoiceFollowUp(
            prompt: 'Opened. You can ask me to change or refine that.');
        return;
      case VoiceFollowUpKind.repeat:
        final repeat = _voiceContext.repeatCommandText ?? _lastVoiceCommandText;
        if (repeat == null) {
          await _beginVoiceFollowUp(
              prompt: 'There is no previous voice command to repeat.');
          return;
        }
        await _executeVoiceCommand(repeat);
        return;
      case VoiceFollowUpKind.undo:
        await _undoLastVoiceTurn();
        return;
      case VoiceFollowUpKind.clarification:
        await _beginVoiceFollowUp(
          prompt: resolution.message.isEmpty
              ? 'Tell me what I should change.'
              : resolution.message,
        );
        return;
      case VoiceFollowUpKind.command:
      case VoiceFollowUpKind.correction:
        _pendingVoiceConfirmation = null;
        _voiceCommandBeforeConfirmation = null;
        await _executeVoiceCommand(resolution.commandText);
        return;
    }
  }

  Future<void> _executeVoiceCommand(
    String spokenCommand, {
    bool skipConfirmation = false,
  }) async {
    var commandText = spokenCommand.trim();
    var command = CommandPipeline.interpret(commandText);
    // A free-form voice request is a safe web search, not an arbitrary action.
    if (command.intent.type == UniversalIntentType.unknown) {
      commandText = 'search $commandText';
      command = CommandPipeline.interpret(commandText);
    }
    if (!command.isValid) {
      await _beginVoiceFollowUp(
          prompt: 'I could not safely understand that. Please rephrase it.');
      return;
    }
    if (command.requiresConfirmation && !skipConfirmation) {
      _voiceCommandBeforeConfirmation = _voiceContext.lastCommand;
      _pendingVoiceConfirmation = command;
      _voiceContext.record(command);
      final prompt = _confirmationPrompt(command.intent);
      await _beginVoiceFollowUp(prompt: prompt);
      return;
    }

    _voiceUndoQuery = _query;
    _voiceUndoResults = List<SearchResult>.from(_results);
    _voiceUndoCommand = _activeCommand;
    _voiceUndoIntent = _activeIntent;
    _lastVoiceCommandText = commandText;
    _voiceContext.record(command);
    _setVoiceState(VoiceSessionPhase.processing, status: 'Working on it…');
    await _submitCommand(commandText, fromVoice: true);
    if (!mounted || _voiceStopRequested) return;
    await _beginVoiceFollowUp(
      prompt: _results.isEmpty
          ? 'Done. You can correct that or ask for the next thing.'
          : 'I found ${_results.length} result${_results.length == 1 ? '' : 's'}. You can say “open the second result” or correct me.',
    );
  }

  String _confirmationPrompt(UniversalIntent intent) {
    final instruction = switch (intent.type) {
      UniversalIntentType.callContact => 'Call ${intent.target}',
      UniversalIntentType.smsContact => 'Send that message to ${intent.target}',
      UniversalIntentType.whatsappContact =>
        'Send that WhatsApp message to ${intent.target}',
      _ => 'Run that action',
    };
    final yes = _requireWakePhrase ? '“Apex AI, yes”' : '“yes”';
    return '$instruction? Say $yes to confirm or “cancel”.';
  }

  Future<void> _undoLastVoiceTurn() async {
    final previousResults = _voiceUndoResults;
    final previousCommand = _voiceUndoCommand;
    final previousIntent = _voiceUndoIntent;
    if (previousResults == null ||
        previousCommand == null ||
        previousIntent == null) {
      await _beginVoiceFollowUp(
          prompt: 'There is no previous search state to restore.');
      return;
    }
    final nonReversible =
        _activeIntent.type == UniversalIntentType.callContact ||
            _activeIntent.type == UniversalIntentType.smsContact ||
            _activeIntent.type == UniversalIntentType.whatsappContact ||
            _activeIntent.type == UniversalIntentType.openApp ||
            _activeIntent.type == UniversalIntentType.searchInApp;
    final query = _voiceUndoQuery ?? '';
    _controller.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    setState(() {
      _query = query;
      _results = List<SearchResult>.from(previousResults);
      _activeCommand = previousCommand;
      _activeIntent = previousIntent;
    });
    _voiceContext.restore(previousCommand);
    _voiceUndoResults = null;
    await _beginVoiceFollowUp(
      prompt: nonReversible
          ? 'I restored the previous screen, but an external call or message cannot be undone.'
          : 'I restored the previous results. What should I do next?',
    );
  }

  Future<void> _speakVoicePrompt(String message) async {
    if (!_spokenResponses || message.trim().isEmpty) return;
    try {
      await searchPlatformChannel
          .invokeMethod<bool>('speakVoicePrompt', {'text': message}).timeout(
        const Duration(seconds: 8),
      );
    } catch (_) {
      // Spoken prompts are an enhancement; visual controls stay available.
    }
  }

  Future<void> _stopVoicePrompt() async {
    try {
      await searchPlatformChannel.invokeMethod<void>('stopVoicePrompt');
    } catch (_) {}
  }

  Future<void> _endVoiceConversation({String? message}) async {
    _voiceStopRequested = true;
    _voiceResumePending = false;
    _voiceRestartTimer?.cancel();
    _voiceFollowUpTimer?.cancel();
    _voiceFollowUpDeadline = null;
    _voiceFollowUpMode = false;
    _pendingVoiceConfirmation = null;
    _voiceCommandBeforeConfirmation = null;
    _voiceListenGeneration++;
    _voicePromptGeneration++;
    await _stopVoicePrompt();
    try {
      await _speechToText.cancel();
    } catch (_) {}
    if (!mounted) return;
    _setVoiceState(VoiceSessionPhase.idle, status: 'Say what you need');
    if (message != null && message.isNotEmpty) _showMessage(message);
  }

  Future<void> _toggleVoiceSearch() async {
    if (_voiceConversationActive || _isListening) {
      if (!_isListening &&
          (_voicePhase == VoiceSessionPhase.awaitingFollowUp ||
              _voicePhase == VoiceSessionPhase.confirming)) {
        _voicePromptGeneration++;
        await _stopVoicePrompt();
        await _startVoiceListening(followUp: true, keepDeadline: true);
        return;
      }
      if (_isListening && _voiceTranscript.trim().isNotEmpty) {
        final generation = _voiceListenGeneration;
        try {
          await _speechToText.stop();
        } catch (_) {}
        await _finishVoiceCommand(generation);
      } else {
        await _endVoiceConversation();
      }
      return;
    }
    await _loadVoicePreferences();
    _voiceStopRequested = false;
    _voiceFollowUpMode = false;
    _pendingVoiceConfirmation = null;
    _voiceCommandBeforeConfirmation = null;
    await _startVoiceListening();
  }

  Future<void> _loadSources() async {
    try {
      final result =
          await searchPlatformChannel.invokeMethod<Map>('getInitialData');
      if (result != null && mounted) {
        final historyJson = result['history'] as String? ?? '[]';
        final List<dynamic> historyList = jsonDecode(historyJson);
        final history = historyList
            .map((item) => HistoryEntryCodec.decodeInitialSnapshot(
                  Map<String, dynamic>.from(item),
                ))
            .toList();

        final List<dynamic> appsRaw = result['apps'] ?? [];
        final apps = appsRaw.map((a) => Map<String, String>.from(a)).toList();

        final List<dynamic> contactsRaw = result['contacts'] ?? [];
        final contacts = contactsRaw
            .map((c) => IndexedContact(
                  name: '${c['name'] ?? ''}',
                  phone: '${c['phone'] ?? ''}',
                ))
            .toList();

        setState(() {
          _history = history;
          _apps
            ..clear()
            ..addAll(apps);
          _contacts
            ..clear()
            ..addAll(contacts);
          _loadingApps = apps.isEmpty;
          _loadingContacts = contacts.isEmpty;
        });
        widget.onHistoryChanged(_history);
      }
    } on MissingPluginException {
      // Native search sources are unavailable in browser previews.
      if (mounted) {
        setState(() {
          _loadingApps = false;
          _loadingContacts = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading initial data: $e');
    }

    // Contacts are needed for direct actions; heavier package/icon and file
    // queries are delayed until the first screen is interactive.
    if (!mounted) return;
    unawaited(_loadContacts());
    _startupAppsTimer?.cancel();
    _startupAppsTimer = Timer(
      const Duration(milliseconds: 120),
      _loadApps,
    );
    _startupDocumentsTimer?.cancel();
    _startupDocumentsTimer = Timer(
      const Duration(milliseconds: 550),
      _loadDocuments,
    );
  }

  Future<void> _loadHistory() async {
    try {
      final String? result =
          await searchPlatformChannel.invokeMethod<String>('getHistory');
      if (mounted && result != null) {
        final List<dynamic> jsonList = jsonDecode(result);
        setState(() {
          _history = jsonList
              .map((item) => HistoryEntryCodec.decode(
                    Map<String, dynamic>.from(item),
                  ))
              .toList();
        });
        widget.onHistoryChanged(_history);
      }
    } on MissingPluginException {
      // Native history is unavailable in browser previews.
    } catch (e) {
      debugPrint('Error loading history: $e');
    }
  }

  Future<void> _saveToHistory(SearchResult result) async {
    try {
      await searchPlatformChannel.invokeMethod(
        'addToHistory',
        HistoryEntryCodec.encode(result,
            query: _query, timestamp: DateTime.now()),
      );
      await _loadHistory();
    } catch (_) {}
  }

  Future<void> _clearAllHistory() async {
    try {
      for (final item in _history) {
        await searchPlatformChannel.invokeMethod('removeFromHistory', {
          'title': item.title,
          'kind': item.kind.name,
        });
      }
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(PreferenceKeys.localConversation);
      if (mounted) {
        setState(() {
          _conversationTurns = [];
          _activeConversationTurnId = null;
        });
      }
      await _loadHistory();
    } catch (_) {}
  }

  Future<void> _loadContacts() async {
    try {
      final allowed = await searchPlatformChannel
              .invokeMethod<bool>('requestContactsPermission') ??
          false;

      if (!allowed) {
        if (!mounted) return;
        setState(() {
          _contactsPermissionDenied = true;
          _loadingContacts = false;
        });
        return;
      }

      final result = await searchPlatformChannel
          .invokeMethod<List<dynamic>>('getContacts');
      final contacts = (result ?? [])
          .whereType<Map>()
          .map(
            (contact) => IndexedContact(
              name: '${contact['name'] ?? ''}',
              phone: _phoneNumberFrom('${contact['phone'] ?? ''}') ?? '',
            ),
          )
          .where((contact) => contact.name.trim().isNotEmpty)
          .where((contact) => contact.phone.trim().isNotEmpty)
          .toList()
        ..sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );

      if (!mounted) return;
      setState(() {
        _contacts
          ..clear()
          ..addAll(contacts);
        _contactsPermissionDenied = false;
        _loadingContacts = false;
      });
      if (_query.isNotEmpty) _refreshResults(_query);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingContacts = false);
    }
  }

  Future<void> _loadApps() async {
    try {
      final result =
          await searchPlatformChannel.invokeMethod<List<dynamic>>('getApps');
      final apps = (result ?? [])
          .whereType<Map>()
          .map(
            (app) => {
              'name': '${app['name'] ?? ''}',
              'package': '${app['package'] ?? ''}',
              'icon': '${app['icon'] ?? ''}',
            },
          )
          .where((app) => app['name']!.trim().isNotEmpty)
          .toList()
        ..sort(
          (a, b) => a['name']!.toLowerCase().compareTo(
                b['name']!.toLowerCase(),
              ),
        );

      if (!mounted) return;
      setState(() {
        _apps
          ..clear()
          ..addAll(apps);
        _loadingApps = false;
      });
      if (_query.isNotEmpty) _refreshResults(_query);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingApps = false);
    }
  }

  Future<void> _loadDocuments({
    bool force = false,
    bool startIndexing = true,
  }) async {
    if (_documentLoadInFlight || (_documentsLoaded && !force)) return;
    _documentLoadInFlight = true;
    final documentsByPath = <String, IndexedDocument>{};
    final pathlessDocuments = <IndexedDocument>[..._starterDocuments];

    try {
      final result = await searchPlatformChannel
          .invokeMethod<List<dynamic>>('getDocuments');
      for (final item in result ?? const <dynamic>[]) {
        if (item is! Map) continue;
        final document = documentFromPlatformMap(item);
        if (document.name.trim().isEmpty) continue;
        if (document.path == null) {
          pathlessDocuments.add(document);
        } else {
          documentsByPath[document.path!] = document;
        }
      }
    } catch (_) {}

    // Merge the private content index over the lightweight MediaStore rows.
    // This supplies OCR text, classification, and embeddings even when the
    // filename itself is meaningless.
    try {
      final indexed = await searchPlatformChannel
          .invokeMethod<List<dynamic>>('getDocumentIndex');
      for (final item in indexed ?? const <dynamic>[]) {
        if (item is! Map) continue;
        final document = documentFromPlatformMap(item);
        if (document.name.trim().isEmpty) continue;
        if (document.path == null) {
          pathlessDocuments.add(document);
        } else {
          documentsByPath[document.path!] = document;
        }
      }
    } catch (_) {}

    if (!mounted) return;
    _documentsLoaded = true;
    _documentLoadInFlight = false;
    setState(() {
      _documents
        ..clear()
        ..addAll(pathlessDocuments)
        ..addAll(documentsByPath.values);
      _loadingDocuments = false;
    });
    if (_query.isNotEmpty) _refreshResults(_query);
    if (startIndexing) unawaited(_startDocumentIndexing());
  }

  bool _shouldSearchNativeDocuments(UniversalIntent intent, String query) {
    if (intent.type == UniversalIntentType.searchDocuments) return true;
    if (intent.type != UniversalIntentType.unknown) return false;
    final normalized = DocumentIntelligence.normalize(query);
    // Generic terms can be inside a file without the query containing words
    // such as "document" or "PDF". Search the native full-text index for
    // every useful free-form query, not only document-shaped sentences.
    return normalized.length >= 2;
  }

  Future<void> _cancelNativeDocumentSearch() async {
    final requestId = ++_nativeDocumentSearchGeneration;
    _nativeDocumentSearchInFlight = false;
    _nativeDocumentSearchAt = null;
    _nativeDocumentSearchCompleteQuery = null;
    try {
      await searchPlatformChannel.invokeMethod<bool>(
        'cancelDocumentSearch',
        {'requestId': requestId},
      );
    } catch (_) {
      // Desktop previews and older native hosts may not expose cancellation.
    }
  }

  Future<void> _prepareSemanticSearchStorage() async {
    try {
      await searchPlatformChannel
          .invokeMethod<bool>('prepareSemanticSearchStorage');
    } catch (_) {
      // Not available in desktop previews or older Android hosts.
    }
  }

  Future<void> _pickNotesToImport() async {
    try {
      final selected =
          await searchPlatformChannel.invokeMethod<bool>('pickNotesToImport');
      if (selected == true && mounted) {
        await _promptForSharedDocuments();
      }
    } on PlatformException catch (error) {
      if (mounted) _showMessage(error.message ?? 'Could not open files.');
    } on MissingPluginException {
      if (mounted) _showMessage('File import is available on Android.');
    }
  }

  Future<void> _promptForSharedDocuments() async {
    if (_importPromptOpen || !mounted) return;
    _importPromptOpen = true;
    try {
      final pending = await searchPlatformChannel
          .invokeMethod<Map<dynamic, dynamic>>('getPendingSharedDocuments');
      if (!mounted) return;
      final names = (pending?['names'] as List?)?.cast<String>() ?? const [];
      if (names.isEmpty) return;
      var selectedSubject = '${pending?['subject'] ?? ''}'.trim();
      final subject = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Import class notes'),
          content: SingleChildScrollView(
              child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(names.length == 1
                  ? names.first
                  : '${names.length} selected files'),
              const SizedBox(height: 12),
              const Text(
                  'Enter the subject so these notes appear when you search for it.'),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: selectedSubject,
                onChanged: (value) => selectedSubject = value,
                autofocus: false,
                maxLength: 70,
                decoration: const InputDecoration(
                  labelText: 'Subject',
                  hintText: 'e.g. Data Compression',
                ),
              ),
            ],
          )),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = selectedSubject.trim();
                if (value.isNotEmpty) Navigator.pop(dialogContext, value);
              },
              child: const Text('Import'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (subject == null) {
        await searchPlatformChannel
            .invokeMethod<bool>('dismissPendingSharedDocuments');
        return;
      }
      final outcome =
          await searchPlatformChannel.invokeMethod<Map<dynamic, dynamic>>(
        'importSharedDocuments',
        {'subject': subject},
      );
      if (!mounted) return;
      final imported = outcome?['imported'] as int? ?? 0;
      final failed = outcome?['failed'] as int? ?? 0;
      if (imported > 0) {
        _nativeDocumentSearchCompleteQuery = null;
        _nativeDocumentSearchQuery = null;
        _nativeDocumentSearchAt = null;
        _nativeDocumentMatches.clear();
        await _loadDocuments(force: true, startIndexing: false);
        _monitorDocumentIndexing();
        _showMessage(
            'Imported $imported note${imported == 1 ? '' : 's'} for $subject. Content indexing is running.');
      }
      if (failed > 0) {
        _showMessage(
            '$failed file${failed == 1 ? '' : 's'} could not be imported: ${outcome?['error'] ?? ''}');
      }
    } on PlatformException catch (error) {
      if (mounted) _showMessage(error.message ?? 'Could not import notes.');
    } on MissingPluginException {
      // Desktop previews do not provide the Android attachment flow.
    } finally {
      _importPromptOpen = false;
    }
  }

  Future<void> _requestNativeDocumentSearch(String query) async {
    String currentDocumentQuery() {
      final intent = CommandPipeline.interpret(_query).intent;
      return intent.type == UniversalIntentType.searchDocuments
          ? intent.target
          : _query;
    }

    final normalized = DocumentIntelligence.normalize(query);
    final searchedRecently = _nativeDocumentSearchQuery == normalized &&
        _nativeDocumentSearchAt != null &&
        DateTime.now().difference(_nativeDocumentSearchAt!) <
            const Duration(seconds: 2);
    final sameQueryInFlight = _nativeDocumentSearchInFlight &&
        _nativeDocumentSearchQuery == normalized;
    if (normalized.isEmpty ||
        _nativeDocumentSearchCompleteQuery == normalized ||
        sameQueryInFlight ||
        searchedRecently ||
        !_shouldSearchNativeDocuments(
          UniversalActionParser.parse(query),
          query,
        )) {
      return;
    }
    final generation = ++_nativeDocumentSearchGeneration;
    _nativeDocumentSearchInFlight = true;
    _nativeDocumentSearchQuery = normalized;
    _nativeDocumentSearchAt = DateTime.now();
    try {
      void applyMatches(List<dynamic>? raw) {
        _nativeDocumentMatches.clear();
        for (final item in raw ?? const <dynamic>[]) {
          if (item is! Map || item['path'] == null) continue;
          final path = '${item['path']}';
          final previous = _nativeDocumentMatches[path];
          final row = Map<dynamic, dynamic>.from(item);
          if (previous != null) {
            row['content'] = '${previous.context}\n${item['content'] ?? ''}';
          }
          _nativeDocumentMatches[path] = documentFromPlatformMap(row);
        }
      }

      // Show exact filename/content matches first. This avoids making the
      // result list wait for a brute-force semantic-vector pass.
      final fast = await searchPlatformChannel.invokeMethod<List<dynamic>>(
        'searchDocuments',
        {
          'query': query,
          'includeSemantic': false,
          'requestId': generation,
        },
      );
      if (!mounted || generation != _nativeDocumentSearchGeneration) return;
      applyMatches(fast);
      _nativeDocumentSearchQuery = normalized;
      _nativeDocumentSearchAt = DateTime.now();
      if (_query.isNotEmpty &&
          DocumentIntelligence.normalize(currentDocumentQuery()) ==
              normalized) {
        _refreshResults(_query);
      }
      if (DocumentIntelligence.normalize(currentDocumentQuery()) !=
          normalized) {
        return;
      }

      // Preserve the existing semantic recall and ordering, but let it enrich
      // the already visible exact results when it completes.
      final enriched = await searchPlatformChannel.invokeMethod<List<dynamic>>(
        'searchDocuments',
        {
          'query': query,
          'includeSemantic': true,
          'requestId': generation,
        },
      );
      if (!mounted || generation != _nativeDocumentSearchGeneration) return;
      applyMatches(enriched);
      _nativeDocumentSearchCompleteQuery = normalized;
      _nativeDocumentSearchAt = DateTime.now();
      if (_query.isNotEmpty &&
          DocumentIntelligence.normalize(currentDocumentQuery()) ==
              normalized) {
        _refreshResults(_query);
      }
    } catch (_) {
      if (generation == _nativeDocumentSearchGeneration) {
        _nativeDocumentSearchQuery = normalized;
      }
    } finally {
      if (generation == _nativeDocumentSearchGeneration) {
        _nativeDocumentSearchInFlight = false;
        // Empty native replies may reuse an already-ranked result set. Notify
        // the UI even when no new ranking completion will clear its spinner.
        if (mounted) setState(() {});
        final current = DocumentIntelligence.normalize(currentDocumentQuery());
        if (current.isNotEmpty && current != normalized) {
          _fileSearchDebounceTimer?.cancel();
          _fileSearchDebounceTimer =
              Timer(const Duration(milliseconds: 350), () {
            if (mounted) _refreshResults(_query);
          });
        }
      }
    }
  }

  Future<void> _requestCloudDocumentSearch(String query) async {
    final normalized = DocumentIntelligence.normalize(query);
    if (normalized.isEmpty ||
        _cloudSearchInFlight ||
        _cloudDocumentQuery == normalized) {
      return;
    }
    _cloudSearchInFlight = true;
    _cloudDocumentQuery = normalized;
    try {
      final hits = await _cloudIndexRepository.search(query);
      if (!mounted || _cloudDocumentQuery != normalized) return;
      final locators = await _cloudIndexRepository.store.loadLocators();
      _cloudDocumentResults = hits
          .map((hit) => hit.toSearchResult(locators[hit.documentId]))
          .toList();
      _cloudSearchOffline = false;
      if (DocumentIntelligence.normalize(_query) == normalized) {
        _refreshResults(_query);
      }
    } catch (_) {
      if (!mounted || _cloudDocumentQuery != normalized) return;
      _cloudDocumentResults = const [];
      _cloudSearchOffline = true;
      setState(() {});
    } finally {
      _cloudSearchInFlight = false;
      final current = DocumentIntelligence.normalize(_query);
      if (mounted && current.isNotEmpty && current != normalized) {
        unawaited(_requestCloudDocumentSearch(_query));
      }
    }
  }

  Future<void> _startDocumentIndexing({bool forceRecovery = false}) async {
    if (_documentIndexing) return;
    if (forceRecovery) _requestedAllFilesAccess = false;
    _documentIndexing = true;
    try {
      final started = await searchPlatformChannel.invokeMethod<bool>(
        'startDocumentIndexing',
        {'forceRecovery': forceRecovery},
      );
      if (started == true) _monitorDocumentIndexing();
    } on MissingPluginException {
      // Native device indexing is unavailable in web/desktop previews.
    } on PlatformException catch (error) {
      if (error.code == 'FILES_PERMISSION_REQUIRED') {
        _showMessage(
            'Enable “All files access” to build your private phone-wide search index.');
        if (!_requestedAllFilesAccess) {
          _requestedAllFilesAccess = true;
          await searchPlatformChannel.invokeMethod<bool>(
            'requestAllFilesAccess',
            {'forceRecovery': forceRecovery},
          );
        }
        return;
      }
      debugPrint('Document indexing could not start: ${error.code}');
    } finally {
      _documentIndexing = false;
    }
  }

  void _monitorDocumentIndexing() {
    _documentIndexPollTimer?.cancel();
    unawaited(_pollDocumentIndex());
    _documentIndexPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_pollDocumentIndex());
    });
  }

  Future<void> _pollDocumentIndex() async {
    try {
      final status =
          await searchPlatformChannel.invokeMethod<Map<dynamic, dynamic>>(
        'getDocumentIndexStatus',
      );
      if (!mounted) return;
      if (status == null) {
        _documentIndexPollTimer?.cancel();
        _documentIndexPollTimer = null;
        return;
      }
      final revision = int.tryParse('${status['revision'] ?? 0}') ?? 0;
      final complete = status['complete'] == true;
      final state = complete ? 'complete' : '${status['state'] ?? 'queued'}';
      final indexed = int.tryParse('${status['indexed'] ?? 0}') ?? 0;
      final total = int.tryParse('${status['total'] ?? 0}') ?? 0;
      final currentFile = '${status['currentFile'] ?? ''}';
      final lastError = '${status['lastError'] ?? ''}';
      final scheduleStartMinute =
          int.tryParse('${status['scheduleStartMinute'] ?? 0}') ?? 0;
      final scheduleEndMinute = int.tryParse(
            '${status['scheduleEndMinute'] ?? 7 * 60}',
          ) ??
          7 * 60;
      if (state != _documentIndexState ||
          indexed != _documentIndexedFiles ||
          total != _documentTotalFiles ||
          currentFile != _documentIndexCurrentFile ||
          lastError != _documentIndexLastError ||
          scheduleStartMinute != _documentIndexScheduleStartMinute ||
          scheduleEndMinute != _documentIndexScheduleEndMinute) {
        setState(() {
          _documentIndexState = state;
          _documentIndexedFiles = indexed;
          _documentTotalFiles = total;
          _documentIndexCurrentFile = currentFile;
          _documentIndexLastError = lastError;
          _documentIndexScheduleStartMinute =
              scheduleStartMinute.clamp(0, 1439).toInt();
          _documentIndexScheduleEndMinute =
              scheduleEndMinute.clamp(0, 1439).toInt();
        });
      }
      final typing = (_debounceTimer?.isActive ?? false) ||
          (_fileSearchDebounceTimer?.isActive ?? false);
      if (!typing && revision > 0 && revision != _documentIndexRevision) {
        _documentIndexRevision = revision;
        _nativeDocumentSearchAt = null;
        _nativeDocumentSearchCompleteQuery = null;
        _nativeDocumentSearchQuery = null;
        _nativeDocumentMatches.clear();
        await _loadDocuments(force: true, startIndexing: false);
      }
      if (complete && !typing) {
        _documentIndexPollTimer?.cancel();
        _documentIndexPollTimer = null;
      }
    } catch (_) {
      _documentIndexPollTimer?.cancel();
      _documentIndexPollTimer = null;
    }
  }

  String _contactId(IndexedContact contact) {
    final digits = contact.phone.replaceAll(RegExp(r'\D'), '');
    return digits.isNotEmpty ? digits : normalizeEntity(contact.name);
  }

  int _historyUsageForContact(IndexedContact contact) {
    var total = 0;
    final cleanPhone = contact.phone.replaceAll(RegExp(r'\D'), '');
    for (final item in _history) {
      if (item.kind != ResultKind.action) continue;
      final hasName =
          item.title.toLowerCase().contains(contact.name.toLowerCase());
      final hasPhone = cleanPhone.isNotEmpty &&
          (item.url?.toString() ?? '')
              .replaceAll(RegExp(r'\D'), '')
              .contains(cleanPhone);
      if (hasName || hasPhone) total += item.usageCount;
    }
    return total;
  }

  int _systemUsageForContact(IndexedContact contact) {
    final digits = contact.phone.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return 0;
    var total = 0;
    for (final entry in _systemCallCounts.entries) {
      if (entry.key == digits ||
          (entry.key.length >= 10 &&
              digits.length >= 10 &&
              entry.key.endsWith(digits.substring(digits.length - 10)))) {
        total += entry.value;
      }
    }
    return total;
  }

  DateTime? _systemLastCalledForContact(IndexedContact contact) {
    final digits = contact.phone.replaceAll(RegExp(r'\D'), '');
    DateTime? latest;
    for (final entry in _systemLastCalled.entries) {
      final same = entry.key == digits ||
          (entry.key.length >= 10 &&
              digits.length >= 10 &&
              entry.key.endsWith(digits.substring(digits.length - 10)));
      if (same && (latest == null || entry.value.isAfter(latest))) {
        latest = entry.value;
      }
    }
    return latest;
  }

  bool _requestsMostUsedContact(String query) {
    final parsed = UniversalActionParser.parse(query);
    if (parsed.filters['contactSelection'] == 'most_used') return true;
    final normalized = normalizeEntity(
      _isContactIntent(parsed) ? parsed.target : query,
    );
    return _pendingContactIntent != null &&
        (RegExp(
              r'\b(?:most|usually|often|frequently|normally|regularly|majority)\b',
            ).hasMatch(normalized) ||
            normalized.contains('all the time'));
  }

  Future<void> _loadSystemCallUsage() async {
    try {
      final raw = await searchPlatformChannel.invokeMethod<List<dynamic>>(
        'getCallUsage',
        {'requestPermission': true},
      );
      if (raw == null) return;
      _systemCallCounts.clear();
      _systemLastCalled.clear();
      for (final item in raw.whereType<Map>()) {
        final phone = '${item['phone'] ?? ''}'.replaceAll(RegExp(r'\D'), '');
        if (phone.isEmpty) continue;
        _systemCallCounts[phone] = int.tryParse('${item['count'] ?? 0}') ?? 0;
        final milliseconds = int.tryParse('${item['lastCalled'] ?? 0}') ?? 0;
        if (milliseconds > 0) {
          _systemLastCalled[phone] =
              DateTime.fromMillisecondsSinceEpoch(milliseconds);
        }
      }
    } catch (_) {
      // App-local selection history remains a privacy-preserving fallback.
    }
  }

  bool _isAmbiguousContactPhrase(String phrase) {
    final normalizedPhrase = normalizeEntity(phrase);
    if (normalizedPhrase.isEmpty) return false;
    final compactPhrase = normalizedPhrase.replaceAll(' ', '');
    var matches = 0;
    for (final contact in _contacts) {
      final name = normalizeEntity(contact.name);
      final compactName = name.replaceAll(' ', '');
      if (name == normalizedPhrase ||
          name.startsWith('$normalizedPhrase ') ||
          compactName.startsWith(compactPhrase)) {
        matches++;
        if (matches > 1) return true;
      }
    }
    return false;
  }

  List<ContactCandidate> _contactCandidates() {
    final unique = <String, IndexedContact>{};
    for (final contact in _contacts) {
      unique.putIfAbsent(_contactId(contact), () => contact);
    }
    return unique.values.map((contact) {
      final id = _contactId(contact);
      final aliases = _contactAliases.entries
          .where((entry) => entry.value == id)
          .where((entry) => !_isAmbiguousContactPhrase(entry.key))
          .map((entry) => entry.key)
          .toList();
      final appLastSelected = _contactLastSelected[id];
      final systemLastCalled = _systemLastCalledForContact(contact);
      final lastUsed = appLastSelected == null
          ? systemLastCalled
          : systemLastCalled == null ||
                  appLastSelected.isAfter(systemLastCalled)
              ? appLastSelected
              : systemLastCalled;
      return ContactCandidate(
        id: id,
        displayName: contact.name,
        phone: contact.phone,
        aliases: aliases,
        usageCount: _historyUsageForContact(contact) +
            (_contactSelectionCounts[id] ?? 0) +
            _systemUsageForContact(contact),
        lastSelectedAt: lastUsed,
      );
    }).toList();
  }

  List<ContactMatch> _resolveContactMatches(String target) =>
      ContactResolver.resolve(target, _contactCandidates());

  bool _isContactIntent(UniversalIntent intent) =>
      intent.type == UniversalIntentType.callContact ||
      intent.type == UniversalIntentType.whatsappContact ||
      intent.type == UniversalIntentType.smsContact;

  (UniversalIntent, List<ContactMatch>?, bool) _resolveContactContext(
    String query, {
    UniversalIntent? parsedIntent,
  }) {
    final parsed = parsedIntent ?? CommandPipeline.interpret(query).intent;
    if (_isContactIntent(parsed) &&
        parsed.filters['contactSelection'] == 'most_used') {
      final matches = _resolveContactMatches(parsed.target);
      final preferred = ContactResolver.mostFrequentlyUsed(matches);
      return (
        parsed,
        preferred == null ? matches : <ContactMatch>[preferred],
        preferred != null,
      );
    }
    final pendingIntent = _pendingContactIntent;
    final pendingMatches = _pendingContactMatches;
    if (pendingIntent == null || pendingMatches.isEmpty) {
      return (parsed, null, false);
    }

    final normalized = normalizeEntity(query);
    final modeSwitch = RegExp(
      r'^(call|phone|dial|whatsapp|message|sms|text)\s+(?:him|her|them)(?:\s+instead)?$',
      caseSensitive: false,
    ).firstMatch(query.trim());
    if (modeSwitch != null) {
      final command = modeSwitch.group(1)!.toLowerCase();
      final type = command == 'whatsapp'
          ? UniversalIntentType.whatsappContact
          : (command == 'message' || command == 'sms' || command == 'text')
              ? UniversalIntentType.smsContact
              : UniversalIntentType.callContact;
      return (
        UniversalIntent(
          type: type,
          rawText: query,
          target: pendingMatches.first.candidate.displayName,
        ),
        <ContactMatch>[pendingMatches.first],
        true,
      );
    }
    final asksForFrequentContact = RegExp(
          r'\b(?:most|usually|often|frequently|normally|regularly|always|majority)\b',
        ).hasMatch(normalized) ||
        normalized.contains('all the time');
    if (asksForFrequentContact) {
      final preferred = ContactResolver.mostFrequentlyUsed(pendingMatches);
      return (
        UniversalIntent(
          type: pendingIntent.type,
          rawText: query,
          target: preferred?.candidate.displayName ?? pendingIntent.target,
          message: pendingIntent.message,
        ),
        preferred == null ? pendingMatches : <ContactMatch>[preferred],
        preferred != null,
      );
    }

    final ordinalPatterns = <RegExp, int>{
      RegExp(r'\b(?:first|1st|number one|option one|result one|contact one)\b'):
          0,
      RegExp(
        r'\b(?:second|2nd|number two|option two|result two|contact two)\b',
      ): 1,
      RegExp(
        r'\b(?:third|3rd|number three|option three|result three|contact three)\b',
      ): 2,
      RegExp(
        r'\b(?:fourth|4th|number four|option four|result four|contact four)\b',
      ): 3,
      RegExp(
        r'\b(?:fifth|5th|number five|option five|result five|contact five)\b',
      ): 4,
    };
    for (final entry in ordinalPatterns.entries) {
      if (entry.key.hasMatch(normalized) &&
          entry.value < pendingMatches.length) {
        final chosen = pendingMatches[entry.value];
        return (
          UniversalIntent(
            type: pendingIntent.type,
            rawText: query,
            target: chosen.candidate.displayName,
            message: pendingIntent.message,
          ),
          <ContactMatch>[chosen],
          true,
        );
      }
    }

    if (_isContactIntent(parsed) &&
        !RegExp(r'\b(?:one|other|another)\b').hasMatch(normalized)) {
      return (parsed, null, false);
    }

    if (RegExp(r'\bother\b').hasMatch(normalized) &&
        pendingMatches.length > 1) {
      final alternatives = pendingMatches.skip(1).toList();
      return (
        UniversalIntent(
          type: pendingIntent.type,
          rawText: query,
          target: query,
          message: pendingIntent.message,
        ),
        alternatives,
        alternatives.length == 1,
      );
    }

    final qualifier = normalized
        .replaceAll(RegExp(r'\b(?:the|one|person|contact|from|at)\b'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final narrowed = ContactResolver.resolve(
      qualifier,
      pendingMatches.map((match) => match.candidate),
    );
    if (narrowed.isNotEmpty && narrowed.first.textScore >= 0.72) {
      final clearChoice = narrowed.length == 1 ||
          narrowed.first.score - narrowed[1].score >= 0.18;
      return (
        UniversalIntent(
          type: pendingIntent.type,
          rawText: query,
          target: qualifier,
          message: pendingIntent.message,
        ),
        clearChoice ? <ContactMatch>[narrowed.first] : narrowed,
        clearChoice,
      );
    }
    return (parsed, null, false);
  }

  SearchResult _contactActionResult(
      IndexedContact contact, UniversalIntent intent,
      {ContactMatch? match, bool recommended = false}) {
    final label = '${contact.name} (${contact.phone})';
    final usage = match?.candidate.usageCount ?? 0;
    switch (intent.type) {
      case UniversalIntentType.callContact:
        return SearchResult(
          kind: ResultKind.action,
          title: 'Call ${contact.name}',
          subtitle: 'Call directly • $label',
          icon: Icons.call_rounded,
          url: Uri(scheme: 'tel', path: contact.phone),
          usageCount: usage,
          contactName: contact.name,
          contactPhone: contact.phone,
          contactPhrase: intent.target,
          contactConfidence: match?.textScore,
          recommendedContact: recommended,
        );
      case UniversalIntentType.whatsappContact:
        return SearchResult(
          kind: ResultKind.action,
          title: 'WhatsApp ${contact.name}',
          subtitle: intent.message.isEmpty
              ? 'Open chat • $label'
              : 'Send “${intent.message}” • $label',
          icon: Icons.chat_rounded,
          url: Uri(
            scheme: 'whatsapp',
            host: 'send',
            queryParameters: {
              'phone': _whatsAppNumberFrom(contact.phone),
              if (intent.message.isNotEmpty) 'text': intent.message,
            },
          ),
          usageCount: usage,
          contactName: contact.name,
          contactPhone: contact.phone,
          contactPhrase: intent.target,
          contactConfidence: match?.textScore,
          recommendedContact: recommended,
        );
      case UniversalIntentType.smsContact:
        return SearchResult(
          kind: ResultKind.action,
          title: 'Message ${contact.name}',
          subtitle: intent.message.isEmpty
              ? 'Open SMS composer • $label'
              : 'Draft “${intent.message}” • $label',
          icon: Icons.sms_rounded,
          url: Uri(
            scheme: 'sms',
            path: contact.phone,
            queryParameters:
                intent.message.isEmpty ? null : {'body': intent.message},
          ),
          usageCount: usage,
          contactName: contact.name,
          contactPhone: contact.phone,
          contactPhrase: intent.target,
          contactConfidence: match?.textScore,
          recommendedContact: recommended,
        );
      default:
        throw StateError('Not a contact action');
    }
  }

  Future<void> _submitCommand(String raw, {bool fromVoice = false}) async {
    if (_requestsMostUsedContact(raw)) {
      await _loadSystemCallUsage();
    }
    _refreshResults(raw);
    final command = _activeCommand;
    if (!command.isValid) {
      _showMessage('I could not safely understand that command.');
      return;
    }
    final intent = command.intent;
    if (intent.type == UniversalIntentType.unknown ||
        intent.type == UniversalIntentType.searchDocuments) {
      _commitConversationQuery(raw);
      _updateConversationAnswer(_resolveKnowledgeQuery(
        intent.type == UniversalIntentType.searchDocuments
            ? intent.target
            : raw.trim(),
      ));
    }

    if (_isContactIntent(intent)) {
      final phone = _phoneNumberFrom(intent.target);
      if (phone != null) {
        final direct = IndexedContact(name: phone, phone: phone);
        await _openResult(_contactActionResult(direct, intent));
        return;
      }
      final matches = _activeContactMatches;
      if (_contactChosenByFollowUp && matches.length == 1) {
        final chosen = matches.single;
        await _openResult(_contactActionResult(
          IndexedContact(
            name: chosen.candidate.displayName,
            phone: chosen.candidate.phone,
          ),
          intent,
          match: chosen,
          recommended: true,
        ));
        return;
      }
      if (ContactResolver.shouldAutoSelect(matches)) {
        final chosen = matches.first;
        await _openResult(_contactActionResult(
          IndexedContact(
            name: chosen.candidate.displayName,
            phone: chosen.candidate.phone,
          ),
          intent,
          match: chosen,
          recommended: true,
        ));
        return;
      }
      if (matches.isNotEmpty) {
        _showMessage(
          matches.length == 1
              ? 'I found a close contact match. Tap it to confirm.'
              : 'I found ${matches.length} possible contacts. Choose the correct number, say "the second one", or say "the one I call most".',
        );
      } else if (fromVoice) {
        _showMessage('I could not find a close contact for ${intent.target}.');
      }
      return;
    }

    if (intent.type == UniversalIntentType.openApp) {
      final target = normalizeEntity(intent.target);
      final exact = _apps
          .where((app) => normalizeEntity(app['name'] ?? '') == target)
          .toList();
      final prefix = _apps
          .where((app) => normalizeEntity(app['name'] ?? '').startsWith(target))
          .toList();
      final candidates = exact.isNotEmpty ? exact : prefix;
      if (candidates.length == 1) {
        final app = candidates.single;
        await _openResult(SearchResult(
          kind: ResultKind.app,
          title: app['name'] ?? intent.target,
          subtitle: app['package'] ?? '',
          icon: Icons.apps_rounded,
          packageName: app['package'],
          iconBase64: app['icon'],
        ));
      } else if (candidates.length > 1) {
        _showMessage('I found ${candidates.length} matching apps. Choose one.');
      } else if (fromVoice) {
        _showMessage('I could not find ${intent.target} on this device.');
      }
      return;
    }

    if (intent.type == UniversalIntentType.searchInApp) {
      final target = normalizeEntity(intent.target);
      final exact = _apps
          .where((app) => normalizeEntity(app['name'] ?? '') == target)
          .toList();
      final prefix = _apps
          .where((app) => normalizeEntity(app['name'] ?? '').startsWith(target))
          .toList();
      final candidates = exact.isNotEmpty ? exact : prefix;
      if (candidates.length != 1) {
        _showMessage(candidates.isEmpty
            ? 'I could not find ${intent.target} on this device.'
            : 'I found multiple matching apps. Use the full app name.');
        return;
      }
      await _searchInApp(candidates.single['package'], intent.message);
      return;
    }

    if (intent.type == UniversalIntentType.openWebsite) {
      final value = intent.target.startsWith(RegExp(r'https?://'))
          ? intent.target
          : 'https://${intent.target}';
      await _openResult(SearchResult(
        kind: ResultKind.web,
        title: 'Open ${intent.target}',
        subtitle: 'Open website',
        icon: Icons.language_rounded,
        url: Uri.tryParse(value),
      ));
      return;
    }
    if (intent.type == UniversalIntentType.webSearch) {
      await _openResult(SearchResult(
        kind: ResultKind.web,
        title: 'Search the web for "${intent.target}"',
        subtitle: 'Open results in Apex AI',
        icon: Icons.public_rounded,
        url: Uri.https('www.google.com', '/search', {'q': intent.target}),
        webSearchQuery: intent.target,
      ));
      return;
    }
    if (intent.type == UniversalIntentType.navigatePlace) {
      await _openResult(SearchResult(
        kind: ResultKind.web,
        title: 'Navigate to ${intent.target}',
        subtitle: 'Open directions in Maps',
        icon: Icons.directions_rounded,
        url: Uri.https('www.google.com', '/maps/search/',
            {'api': '1', 'query': intent.target}),
      ));
      return;
    }

    if (intent.type == UniversalIntentType.searchDocuments ||
        intent.type == UniversalIntentType.playMusic ||
        intent.type == UniversalIntentType.unknown) {
      return;
    }
  }

  void _refreshResults(
    String rawQuery, {
    bool includeDocumentSearch = true,
  }) {
    final query = rawQuery.trim();
    // Logic for Popular Searches
    if (query.isEmpty) {
      setState(() {
        _query = '';
        _results = [];
        _activeIntent = const UniversalIntent(
          type: UniversalIntentType.unknown,
          rawText: '',
        );
        _activeCommand = const StructuredCommand(
          intent: UniversalIntent(
            type: UniversalIntentType.unknown,
            rawText: '',
          ),
          source: CommandUnderstandingSource.deterministic,
          confidence: 0,
          requiresConfirmation: false,
        );
        _activeContactMatches = const <ContactMatch>[];
        _contactChosenByFollowUp = false;
      });
      return;
    }

    final understoodCommand = CommandPipeline.interpret(query);
    final contactContext = _resolveContactContext(
      query,
      parsedIntent: understoodCommand.intent,
    );
    final intent = contactContext.$1;
    final contextualContactMatches = contactContext.$2;
    final contactChosenByFollowUp = contactContext.$3;
    final command = _sameIntent(intent, understoodCommand.intent)
        ? understoodCommand
        : CommandValidator.validate(
            intent,
            source: CommandUnderstandingSource.deterministic,
            confidence: 1,
          );
    final lookupQuery = switch (intent.type) {
      UniversalIntentType.callContact ||
      UniversalIntentType.whatsappContact ||
      UniversalIntentType.smsContact ||
      UniversalIntentType.openApp ||
      UniversalIntentType.searchInApp ||
      UniversalIntentType.playMusic =>
        intent.target,
      UniversalIntentType.searchDocuments => intent.target,
      _ => query,
    };
    final documentQuery = _resolveKnowledgeQuery(
      intent.type == UniversalIntentType.searchDocuments
          ? intent.target
          : query,
    );
    final allowsApps = intent.type == UniversalIntentType.unknown ||
        intent.type == UniversalIntentType.openApp ||
        intent.type == UniversalIntentType.searchInApp;
    final allowsContacts = intent.type == UniversalIntentType.unknown ||
        intent.type == UniversalIntentType.callContact ||
        intent.type == UniversalIntentType.whatsappContact ||
        intent.type == UniversalIntentType.smsContact;
    final allowsDocuments = includeDocumentSearch &&
        (intent.type == UniversalIntentType.unknown ||
            intent.type == UniversalIntentType.searchDocuments);

    if (allowsDocuments) {
      _requestSemanticEmbedding(documentQuery);
      unawaited(_requestNativeDocumentSearch(documentQuery));
      unawaited(_requestCloudDocumentSearch(documentQuery));
    }

    final normalizedQuery = lookupQuery.toLowerCase();
    final cleanQuery = normalizedQuery.replaceAll(' ', '');
    final phoneNumber = allowsContacts ? _phoneNumberFrom(lookupQuery) : null;
    final results = <SearchResult>[];

    int getAppBoost(String title) {
      final historyItem = _history.firstWhere(
        (h) => h.title == title && h.kind == ResultKind.app,
        orElse: () => const SearchResult(
          kind: ResultKind.web,
          title: '',
          subtitle: '',
          icon: Icons.search,
        ),
      );
      return historyItem.usageCount * 100; // Increased boost weight
    }

    // 1. Get APP matches with refined scoring
    DateTime? appLastUsed(String title) => _history
            .where((item) => item.kind == ResultKind.app && item.title == title)
            .fold<DateTime?>(null, (latest, item) {
          final timestamp = item.timestamp;
          if (timestamp == null ||
              (latest != null && !timestamp.isAfter(latest))) {
            return latest;
          }
          return timestamp;
        });

    final appMatches = _apps
        .where((_) => allowsApps)
        .map((app) {
          final fullName = app['name']!.toLowerCase();
          final cleanName = fullName.replaceAll(' ', '');
          final package = app['package']!.toLowerCase();
          int similarity = 0;

          if (fullName == normalizedQuery || cleanName == cleanQuery) {
            similarity = 10000; // Absolute exact match
          } else if (fullName.startsWith(normalizedQuery) ||
              cleanName.startsWith(cleanQuery)) {
            similarity = 5000; // Prefix match
          } else if (fullName.contains(normalizedQuery) ||
              cleanName.contains(cleanQuery)) {
            similarity = 100; // Reduced score for contains match
          } else if (package.contains(normalizedQuery)) {
            similarity = 50;
          }

          return {
            'app': app,
            'similarity': similarity,
            'lastUsed': appLastUsed(app['name']!),
          };
        })
        .where((match) => (match['similarity'] as int) > 0)
        .toList()
      ..sort((a, b) {
        final bySimilarity =
            (b['similarity'] as int).compareTo(a['similarity'] as int);
        if (bySimilarity != 0) return bySimilarity;
        final aUsed = a['lastUsed'] as DateTime?;
        final bUsed = b['lastUsed'] as DateTime?;
        if (aUsed != null || bUsed != null) {
          if (aUsed == null) return 1;
          if (bUsed == null) return -1;
          final byRecency = bUsed.compareTo(aUsed);
          if (byRecency != 0) return byRecency;
        }
        final aName = (a['app'] as Map<String, String>)['name']!;
        final bName = (b['app'] as Map<String, String>)['name']!;
        return aName.toLowerCase().compareTo(bName.toLowerCase());
      });

    // 2. Resolve contacts with spelling, pronunciation, aliases, and usage.
    final resolvedContacts = !allowsContacts
        ? const <ContactMatch>[]
        : contextualContactMatches ?? _resolveContactMatches(lookupQuery);
    // A generic search should only surface a contact for a strong text match.
    // Fuzzy and phonetic matching remain available for explicit call/message
    // commands, where a person is clearly the intended target.
    final matchedContacts = _isContactIntent(intent)
        ? resolvedContacts
        : resolvedContacts.where((match) => match.textScore >= 0.86).toList();

    // 3. Flat Priority list construction

    // Tier 1: Exact App Matches (Highest Priority)
    final exactApps =
        appMatches.where((m) => (m['similarity'] as int) >= 10000).toList();
    results.addAll(exactApps.map((match) {
      final app = match['app'] as Map<String, String>;
      return SearchResult(
        kind: ResultKind.app,
        title: app['name']!,
        subtitle: app['package']!,
        icon: Icons.apps_rounded,
        packageName: app['package'],
        iconBase64: app['icon'],
        previewBase64: _resultArtwork['app:${app['package']}'],
        usageCount: getAppBoost(app['name']!) ~/ 100,
        relevance: (match['similarity'] as int) / 10000,
        timestamp: match['lastUsed'] as DateTime?,
      );
    }));

    // Tier 2: Contacts
    if (phoneNumber != null &&
        !matchedContacts
            .any((match) => match.candidate.phone.contains(phoneNumber))) {
      final direct = IndexedContact(name: phoneNumber, phone: phoneNumber);
      if (intent.type == UniversalIntentType.callContact ||
          intent.type == UniversalIntentType.whatsappContact ||
          intent.type == UniversalIntentType.smsContact) {
        results.add(_contactActionResult(direct, intent));
      } else {
        for (final type in const [
          UniversalIntentType.whatsappContact,
          UniversalIntentType.callContact,
          UniversalIntentType.smsContact,
        ]) {
          results.add(_contactActionResult(
            direct,
            UniversalIntent(type: type, rawText: query, target: phoneNumber),
          ));
        }
      }
    }

    for (var index = 0; index < matchedContacts.length; index++) {
      final match = matchedContacts[index];
      final contact = IndexedContact(
        name: match.candidate.displayName,
        phone: match.candidate.phone,
      );
      final label = '${contact.name} (${contact.phone})';
      final contactUsage = match.candidate.usageCount;
      final recommended = index == 0 && matchedContacts.length > 1;

      if (_isContactIntent(intent)) {
        results.add(_contactActionResult(
          contact,
          intent,
          match: match,
          recommended: recommended,
        ));
      } else {
        results.addAll([
          SearchResult(
            kind: ResultKind.action,
            title: 'WhatsApp ${contact.name}',
            subtitle: label,
            icon: Icons.chat_rounded,
            url: Uri.parse(
                'whatsapp://send?phone=${_whatsAppNumberFrom(contact.phone)}'),
            usageCount: contactUsage,
            contactName: contact.name,
            contactPhone: contact.phone,
            contactPhrase: lookupQuery,
            contactConfidence: match.textScore,
            recommendedContact: recommended,
          ),
          SearchResult(
            kind: ResultKind.action,
            title: 'Call ${contact.name}',
            subtitle: label,
            icon: Icons.call_rounded,
            url: Uri(scheme: 'tel', path: contact.phone),
            usageCount: contactUsage,
            contactName: contact.name,
            contactPhone: contact.phone,
            contactPhrase: lookupQuery,
            contactConfidence: match.textScore,
            recommendedContact: recommended,
          ),
          SearchResult(
            kind: ResultKind.action,
            title: 'Message ${contact.name}',
            subtitle: label,
            icon: Icons.sms_rounded,
            url: Uri(scheme: 'sms', path: contact.phone),
            usageCount: contactUsage,
            contactName: contact.name,
            contactPhone: contact.phone,
            contactPhrase: lookupQuery,
            contactConfidence: match.textScore,
            recommendedContact: recommended,
          ),
        ]);
      }
    }

    // Tier 3: All other App matches (Prefix, Partial, etc.)
    final otherApps =
        appMatches.where((m) => (m['similarity'] as int) < 10000).toList();
    results.addAll(otherApps.map((match) {
      final app = match['app'] as Map<String, String>;
      return SearchResult(
        kind: ResultKind.app,
        title: app['name']!,
        subtitle: app['package']!,
        icon: Icons.apps_rounded,
        packageName: app['package'],
        iconBase64: app['icon'],
        previewBase64: _resultArtwork['app:${app['package']}'],
        usageCount: getAppBoost(app['name']!) ~/ 100,
        relevance: (match['similarity'] as int) / 10000,
        timestamp: match['lastUsed'] as DateTime?,
      );
    }));

    final nativeMatchesAreCurrent = _nativeDocumentSearchQuery ==
        DocumentIntelligence.normalize(documentQuery);
    // Once native retrieval has answered, rank only its exact FTS, graph, and
    // semantic candidates. Re-ranking every discovered phone file kept the
    // same accuracy signals but made each query scale with the entire library.
    // Before the index answers, retain the small pathless starter suggestions.
    final normalizedDocumentQuery =
        DocumentIntelligence.normalize(documentQuery);
    final queryNameCandidates = _documents.where((document) {
      if (document.path == null) return true;
      final name = DocumentIntelligence.normalize(document.name);
      return normalizedDocumentQuery
          .split(' ')
          .where((term) => term.length >= 2)
          .any(name.contains);
    }).toList();
    final documentCandidates = !allowsDocuments
        ? const <IndexedDocument>[]
        : nativeMatchesAreCurrent
            ? _nativeDocumentMatches.isNotEmpty
                ? _nativeDocumentMatches.values.toList()
                : queryNameCandidates
            : _documents.where((document) => document.path == null).toList();
    final semanticReady = _semanticQueryEmbedding != null &&
        _semanticQueryText == DocumentIntelligence.normalize(documentQuery);
    if (allowsDocuments) {
      _queueDocumentRanking(documentQuery, documentCandidates,
          semanticReady ? _semanticQueryEmbedding : null);
    }
    final matchingDocuments =
        allowsDocuments && _rankedDocumentQuery == documentQuery
            ? _rankedDocuments
            : <MapEntry<IndexedDocument, int>>[];
    final songQuery = intent.type == UniversalIntentType.playMusic
        ? intent.target
        : _songQueryFrom(query);
    if (songQuery != null) {
      results.addAll([
        SearchResult(
          kind: ResultKind.action,
          title: 'Play "$songQuery" on Spotify',
          subtitle: 'Starts playback when Spotify supports the match',
          icon: Icons.music_note_rounded,
          url: Uri(
              scheme: 'music',
              host: 'spotify',
              queryParameters: {'q': songQuery}),
        ),
        SearchResult(
          kind: ResultKind.action,
          title: 'Play "$songQuery" on Apple Music',
          subtitle: 'Starts playback when Apple Music supports the match',
          icon: Icons.music_note_rounded,
          url: Uri(
              scheme: 'music',
              host: 'apple_music',
              queryParameters: {'q': songQuery}),
        ),
      ]);
    }

    // Tier 4: Documents and Web
    results.addAll(
      matchingDocuments.map(
        (match) {
          final doc = match.key;
          return SearchResult(
            kind: ResultKind.document,
            title: doc.name,
            relevance: match.value / 4000,
            timestamp: doc.modifiedAt,
            subtitle: [
              _documentSubtitle(doc),
              if (doc.modifiedAt != null)
                DateFormat('d MMM yyyy').format(doc.modifiedAt!),
              if ((_documentExcerpts[doc.path ?? doc.name] ?? '').isNotEmpty)
                _documentExcerpts[doc.path ?? doc.name]!,
              if (doc.graphReasons.isNotEmpty) doc.graphReasons.first,
            ].join(' • '),
            icon: _documentIcon(doc.type),
            path: doc.path,
            mimeType: doc.type,
            previewBase64:
                doc.path == null ? null : _resultArtwork['file:${doc.path}'],
          );
        },
      ),
    );

    if (intent.type == UniversalIntentType.openWebsite) {
      final value = intent.target.startsWith(RegExp(r'https?://'))
          ? intent.target
          : 'https://${intent.target}';
      results.add(SearchResult(
        kind: ResultKind.web,
        title: 'Open ${intent.target}',
        subtitle: 'Open website',
        icon: Icons.language_rounded,
        url: Uri.tryParse(value),
      ));
    } else if (intent.type == UniversalIntentType.navigatePlace) {
      results.add(SearchResult(
        kind: ResultKind.web,
        title: 'Navigate to ${intent.target}',
        subtitle: 'Open directions in Maps',
        icon: Icons.directions_rounded,
        url: Uri.https('www.google.com', '/maps/search/',
            {'api': '1', 'query': intent.target}),
      ));
    } else if (intent.type == UniversalIntentType.unknown ||
        intent.type == UniversalIntentType.webSearch) {
      final webQuery =
          intent.type == UniversalIntentType.webSearch ? intent.target : query;
      results.add(SearchResult(
        kind: ResultKind.web,
        title: 'Search the web for "$webQuery"',
        subtitle: 'Open results in Apex AI',
        icon: Icons.public_rounded,
        url: Uri.https('www.google.com', '/search', {'q': webQuery}),
        webSearchQuery: webQuery,
      ));
    }

    // A person is one result; actions are presented on that person's card.
    if (allowsDocuments &&
        _cloudDocumentQuery == DocumentIntelligence.normalize(documentQuery)) {
      final merged = mergeHybridResults(results, _cloudDocumentResults);
      results
        ..clear()
        ..addAll(merged);
    }
    if (!_isContactIntent(intent)) {
      final people = <String, List<SearchResult>>{};
      for (final result in results) {
        if (result.contactPhone != null) {
          people.putIfAbsent(result.contactPhone!, () => []).add(result);
        }
      }
      final seen = <String>{};
      final unified = <SearchResult>[];
      for (final result in results) {
        final phone = result.contactPhone;
        if (phone == null) {
          unified.add(result);
        } else if (seen.add(phone)) {
          unified.add(SearchResult(
            kind: ResultKind.action,
            title: result.contactName ?? phone,
            subtitle: phone,
            icon: Icons.person_outline,
            contactName: result.contactName,
            contactPhone: phone,
            relevance: result.contactConfidence ?? 1,
            timestamp: _contactLastSelected[_contactId(IndexedContact(
                name: result.contactName ?? phone, phone: phone))],
            contactActions: people[phone]!,
          ));
        }
      }
      results
        ..clear()
        ..addAll(unified);
    }
    if (!_isContactIntent(intent)) {
      final order = {for (var i = 0; i < results.length; i++) results[i]: i};
      results.sort((a, b) {
        final similarity = b.relevance.compareTo(a.relevance);
        if (similarity != 0) return similarity;
        final recency = (b.timestamp?.millisecondsSinceEpoch ?? 0)
            .compareTo(a.timestamp?.millisecondsSinceEpoch ?? 0);
        return recency != 0 ? recency : order[a]!.compareTo(order[b]!);
      });
    }
    setState(() {
      _query = query;
      // Do not reorder cards beneath a user who has started reading/scrolling.
      // Fresh queries still publish quick results immediately and rank normally.
      if (_readingResultsQuery == query && _results.isNotEmpty) {
        String identity(SearchResult r) =>
            '${r.kind}|${r.title}|${r.path}|${r.contactPhone}|${r.subtitle}';
        _deferredResults = listEquals(
                _results.map(identity).toList(), results.map(identity).toList())
            ? null
            : results;
      } else {
        _results = results;
        _deferredResults = null;
      }
      _activeCommand = command;
      _activeIntent = command.intent;
      _activeContactMatches = matchedContacts;
      _contactChosenByFollowUp = contactChosenByFollowUp;
      if (_isContactIntent(intent) && contextualContactMatches == null) {
        _pendingContactIntent = intent;
        _pendingContactMatches = matchedContacts;
      }
    });
    _queueResultArtwork(_results);
    final deferred = _deferredResults;
    if (deferred != null) _queueResultArtwork(deferred);
  }

  String? _resultArtworkKey(SearchResult result) => switch (result.kind) {
        ResultKind.app when result.packageName?.isNotEmpty == true =>
          'app:${result.packageName}',
        ResultKind.document when result.path?.isNotEmpty == true =>
          'file:${result.path}',
        _ => null,
      };

  void _queueResultArtwork(List<SearchResult> results) {
    if (!_startupEffectsReady) return;
    for (final result in results.take(8)) {
      final key = _resultArtworkKey(result);
      final alreadyHasArtwork = result.previewBase64?.isNotEmpty == true ||
          result.iconBase64?.isNotEmpty == true;
      if (key == null ||
          alreadyHasArtwork ||
          _resultArtwork.containsKey(key) ||
          !_resultArtworkRequests.add(key)) {
        continue;
      }
      unawaited(_loadResultArtwork(result, key));
    }
  }

  Future<void> _loadResultArtwork(SearchResult result, String key) async {
    var artwork = '';
    try {
      artwork = switch (result.kind) {
        ResultKind.app => await searchPlatformChannel.invokeMethod<String>(
                'getAppIcon', {'package': result.packageName}) ??
            '',
        ResultKind.document => await searchPlatformChannel
                .invokeMethod<String>('getDocumentPreview', {
              'path': result.path,
              'mimeType': result.mimeType,
              'name': result.title,
            }) ??
            '',
        _ => '',
      };
    } catch (_) {
      // Artwork is progressive enhancement. The typed fallback remains usable.
    } finally {
      _resultArtworkRequests.remove(key);
      _resultArtwork[key] = artwork;
    }
    if (!mounted || artwork.isEmpty) return;

    SearchResult attach(SearchResult item) =>
        _resultArtworkKey(item) == key ? item.withPreview(artwork) : item;
    setState(() {
      _results = _results.map(attach).toList();
      if (_deferredResults != null) {
        _deferredResults = _deferredResults!.map(attach).toList();
      }
    });
  }

  bool _sameIntent(UniversalIntent left, UniversalIntent right) =>
      left.type == right.type &&
      left.target == right.target &&
      left.message == right.message &&
      mapEquals(left.filters, right.filters);

  void _queueDocumentRanking(
      String query, List<IndexedDocument> documents, List<int>? embedding) {
    final feedbackPrefix = '${DocumentIntelligence.normalize(_query)}|';
    final excludedPaths = documents
        .where((d) =>
            d.path != null &&
            (_documentFeedback['$feedbackPrefix${d.path}'] ?? 0) < 0)
        .map((d) => d.path!)
        .toList();
    final key =
        '$query|${Object.hashAll(documents)}|${Object.hashAll(embedding ?? [])}|${Object.hashAll(excludedPaths)}';
    if (_rankingRequestKey == key) return;
    _rankingRequestKey = key;
    _queuedRanking = {
      'key': key,
      'query': query,
      'embedding': embedding,
      'excludedPaths': excludedPaths,
      'documents': documents
          .map((d) => _preparedDocumentRows[d] ??= <String, dynamic>{
                'name': d.name,
                'type': d.type,
                'path': d.path,
                'content': d.context,
                'summary': d.summary,
                'category': d.category,
                'keywords': d.keywords,
                'embedding': d.embedding,
                'fileEmbedding': d.fileEmbedding,
                'headings': d.headings,
                'folder': d.folder,
                'graphScore': d.graphScore,
                'ftsRank': d.ftsRank,
                'graphRank': d.graphRank,
                'graphReasons': d.graphReasons,
                'usageCount': d.usageCount,
                'lastOpened': d.lastOpened?.millisecondsSinceEpoch ?? 0,
                'modified': d.modifiedAt?.millisecondsSinceEpoch ?? 0,
              })
          .toList(),
    };
    if (!_rankingBusy) unawaited(_drainDocumentRanking());
  }

  Future<void> _drainDocumentRanking() async {
    _rankingBusy = true;
    try {
      while (mounted && _queuedRanking != null) {
        final request = _queuedRanking!;
        _queuedRanking = null;
        final ranked = await _documentSearchService.rank(request);
        if (!mounted || request['key'] != _rankingRequestKey) continue;
        final active = CommandPipeline.interpret(_query).intent;
        final currentQuery = _resolveKnowledgeQuery(
          active.type == UniversalIntentType.searchDocuments
              ? active.target
              : _query,
        );
        if (currentQuery != request['query']) continue;
        _rankedDocumentQuery = request['query'] as String;
        _documentExcerpts.clear();
        _rankedDocuments = ranked.map((row) {
          final doc = IndexedDocument(
            name: row['name'] as String,
            type: row['type'] as String,
            path: row['path'] as String?,
            context: '',
            summary: row['summary'] as String? ?? '',
            category: row['category'] as String? ?? 'document',
            keywords: (row['keywords'] as List?)?.cast<String>() ?? const [],
            folder: row['folder'] as String? ?? '',
            graphScore: (row['graphScore'] as num?)?.toDouble() ?? 0,
            graphReasons:
                (row['graphReasons'] as List?)?.cast<String>() ?? const [],
            usageCount: row['usageCount'] as int? ?? 0,
            lastOpened: (row['lastOpened'] as int? ?? 0) <= 0
                ? null
                : DateTime.fromMillisecondsSinceEpoch(row['lastOpened'] as int),
            modifiedAt: row['modified'] == 0
                ? null
                : DateTime.fromMillisecondsSinceEpoch(row['modified'] as int),
          );
          _documentExcerpts[doc.path ?? doc.name] = row['excerpt'] as String;
          return MapEntry(doc, row['score'] as int);
        }).toList();
        _refreshResults(_query);
        _updateConversationAnswer(currentQuery);
      }
    } catch (error) {
      _rankingRequestKey = null;
      if (mounted) debugPrint('Document search unavailable: $error');
    } finally {
      _rankingBusy = false;
      if (mounted) setState(() {});
    }
  }

  void _requestSemanticEmbedding(String query) {
    final normalized = DocumentIntelligence.normalize(query);
    if (normalized.isEmpty ||
        normalized == _semanticQueryText ||
        normalized == _semanticRequestText) {
      return;
    }
    _semanticDebounceTimer?.cancel();
    _semanticRequestText = normalized;
    _semanticDebounceTimer = Timer(const Duration(milliseconds: 280), () {
      unawaited(() async {
        try {
          final encoded = await searchPlatformChannel.invokeMethod<String>(
            'getTextEmbedding',
            {'text': query},
          );
          if (!mounted || _semanticRequestText != normalized) return;
          final bytes = encoded == null || encoded.isEmpty
              ? null
              : base64Decode(encoded)
                  .map((byte) => byte > 127 ? byte - 256 : byte)
                  .toList();
          _semanticQueryText = normalized;
          _semanticQueryEmbedding = bytes;
          _semanticRequestText = null;
          if (DocumentIntelligence.normalize(_query) == normalized) {
            _refreshResults(_query);
          }
        } catch (_) {
          if (_semanticRequestText == normalized) _semanticRequestText = null;
        }
      }());
    });
  }

  String _feedbackKey(String query, String path) =>
      '${DocumentIntelligence.normalize(query)}|$path';

  Future<void> _loadContactLearning() async {
    final preferences = await SharedPreferences.getInstance();
    try {
      final aliasesRaw =
          preferences.getString(PreferenceKeys.contactChoiceAliases);
      final statsRaw =
          preferences.getString(PreferenceKeys.contactSelectionStats);
      final aliases = aliasesRaw == null ? null : jsonDecode(aliasesRaw);
      final stats = statsRaw == null ? null : jsonDecode(statsRaw);
      if (!mounted) return;
      setState(() {
        if (aliases is Map) {
          _contactAliases
            ..clear()
            ..addAll(aliases.map((key, value) => MapEntry('$key', '$value')));
        }
        if (stats is Map) {
          _contactSelectionCounts.clear();
          _contactLastSelected.clear();
          for (final entry in stats.entries) {
            if (entry.value is! Map) continue;
            final value = entry.value as Map;
            _contactSelectionCounts['${entry.key}'] =
                int.tryParse('${value['count']}') ?? 0;
            final selectedAt = DateTime.tryParse('${value['lastSelectedAt']}');
            if (selectedAt != null) {
              _contactLastSelected['${entry.key}'] = selectedAt;
            }
          }
        }
      });
      if (_query.isNotEmpty) _refreshResults(_query);
    } catch (_) {}
  }

  Future<void> _rememberContactSelection(SearchResult result) async {
    final phone = result.contactPhone;
    if (phone == null || phone.isEmpty) return;
    final id = phone.replaceAll(RegExp(r'\D'), '');
    if (id.isEmpty) return;
    final phrase =
        normalizeEntity(result.contactPhrase ?? _activeIntent.target);
    final ambiguousPhrase = _isAmbiguousContactPhrase(phrase);
    final now = DateTime.now();
    setState(() {
      _contactSelectionCounts[id] = (_contactSelectionCounts[id] ?? 0) + 1;
      _contactLastSelected[id] = now;
      if (phrase.isNotEmpty &&
          !ambiguousPhrase &&
          _phoneNumberFrom(phrase) == null) {
        _contactAliases[phrase] = id;
      } else if (ambiguousPhrase) {
        _contactAliases.remove(phrase);
      }
      _pendingContactIntent = null;
      _pendingContactMatches = const <ContactMatch>[];
    });

    final stats = <String, Map<String, Object>>{};
    for (final entry in _contactSelectionCounts.entries) {
      stats[entry.key] = <String, Object>{
        'count': entry.value,
        'lastSelectedAt':
            (_contactLastSelected[entry.key] ?? now).toIso8601String(),
      };
    }
    final preferences = await SharedPreferences.getInstance();
    await Future.wait([
      preferences.setString(
          PreferenceKeys.contactChoiceAliases, jsonEncode(_contactAliases)),
      preferences.setString(
          PreferenceKeys.contactSelectionStats, jsonEncode(stats)),
    ]);
  }

  Future<void> _loadDocumentFeedback() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(PreferenceKeys.documentSearchFeedback);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || !mounted) return;
      setState(() {
        _documentFeedback
          ..clear()
          ..addAll(decoded.map(
              (key, value) => MapEntry('$key', int.tryParse('$value') ?? 0)));
      });
    } catch (_) {}
  }

  Future<void> _setDocumentFeedback(SearchResult result, int value) async {
    final path = result.path;
    if (path == null || _query.isEmpty) return;
    setState(() {
      _documentFeedback[_feedbackKey(_query, path)] = value;
      _readingResultsQuery = null;
    });
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
        PreferenceKeys.documentSearchFeedback, jsonEncode(_documentFeedback));
    _refreshResults(_query);
  }

  Future<void> _showDocumentFeedback(SearchResult result) async {
    if (result.kind != ResultKind.document) return;
    if (result.documentId != null && !result.localOriginalAvailable) {
      final remove = await showModalBottomSheet<bool>(
        context: context,
        builder: (context) => SafeArea(
          child: ListTile(
            leading: const Icon(Icons.delete_outline_rounded),
            title: const Text('Remove this stale cloud result'),
            subtitle: const Text('The original file is not on this device.'),
            onTap: () => Navigator.pop(context, true),
          ),
        ),
      );
      if (remove == true) {
        try {
          await _cloudIndexRepository.api.deleteDocument(result.documentId!);
          _cloudDocumentQuery = null;
          if (_query.isNotEmpty) _refreshResults(_query);
        } catch (error) {
          _showMessage('Could not remove the cloud result: $error');
        }
      }
      return;
    }
    if (result.path == null) return;
    final importedCopy = Uri.tryParse(result.path!)?.authority ==
        'com.example.smart_search_app.imported_documents';
    final choice = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.thumb_up_alt_outlined),
              title: const Text('Relevant result'),
              subtitle: const Text('Keep this file eligible for this search'),
              onTap: () => Navigator.pop(context, 1),
            ),
            ListTile(
              leading: const Icon(Icons.thumb_down_alt_outlined),
              title: const Text('Not relevant'),
              subtitle: const Text('Hide this file for searches like this'),
              onTap: () => Navigator.pop(context, -1),
            ),
            if (importedCopy)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('Remove imported copy'),
                subtitle:
                    const Text('Keep the original Gmail attachment or file'),
                onTap: () => Navigator.pop(context, 2),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 2) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Remove imported copy?'),
          content: Text(
              'Apex AI will remove ${result.title} from its private notes. The original attachment stays where it was.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      try {
        final removed = await searchPlatformChannel.invokeMethod<bool>(
          'removeImportedDocument',
          {'path': result.path},
        );
        if (!mounted) return;
        if (removed != true) {
          _showMessage('This imported copy is no longer available.');
          return;
        }
        unawaited(_cancelNativeDocumentSearch());
        _nativeDocumentSearchCompleteQuery = null;
        _nativeDocumentSearchQuery = null;
        _nativeDocumentSearchAt = null;
        _nativeDocumentMatches.remove(result.path);
        _rankedDocumentQuery = null;
        _rankedDocuments = [];
        _rankingRequestKey = null;
        await _loadDocuments(force: true, startIndexing: false);
        _monitorDocumentIndexing();
        _showMessage('Imported copy removed.');
      } on PlatformException catch (error) {
        if (mounted) {
          _showMessage(error.message ?? 'Could not remove the imported copy.');
        }
      }
    } else if (choice != null) {
      await _setDocumentFeedback(result, choice);
    }
  }

  String _documentSubtitle(IndexedDocument document) {
    // Never run inference while constructing result cards on the UI isolate.
    // Matching excerpts have already been prepared by the search worker.
    final type = document.type.toLowerCase();
    if (type.contains('pdf')) return 'PDF';
    if (type.contains('word') || type.contains('doc')) return 'Document';
    if (type.contains('sheet') || type.contains('xls')) return 'Spreadsheet';
    if (type.contains('presentation') || type.contains('ppt')) {
      return 'Presentation';
    }
    if (type.startsWith('image/')) {
      return '${type.split('/').last.toUpperCase()} image';
    }
    if (type.startsWith('text/')) return 'Text file';
    return 'File';
  }

  String? _phoneNumberFrom(String query) {
    final digits = query.replaceAll(RegExp(r'[^0-9+]'), '');
    final digitCount = RegExp(r'\d').allMatches(digits).length;

    if (digitCount < 7) return null;
    if (digits.startsWith('+')) {
      return '+${digits.substring(1).replaceAll('+', '')}';
    }
    return digits.replaceAll('+', '');
  }

  String _whatsAppNumberFrom(String phone) {
    return phone.replaceAll(RegExp(r'\D'), '');
  }

  String? _songQueryFrom(String query) {
    final match = RegExp(r'^(?:play|song|music)\s+(.+)$', caseSensitive: false)
        .firstMatch(query.trim());
    final song = match?.group(1)?.trim();
    return song == null || song.isEmpty ? null : song;
  }

  IconData _documentIcon(String type) {
    final lowerType = type.toLowerCase();
    if (lowerType.contains('pdf')) return Icons.picture_as_pdf_rounded;
    if (lowerType.contains('spreadsheet') || lowerType.contains('xls')) {
      return Icons.table_chart_rounded;
    }
    if (lowerType.contains('slide') || lowerType.contains('ppt')) {
      return Icons.slideshow_rounded;
    }
    return Icons.description_rounded;
  }

  Future<void> _openResult(SearchResult result) async {
    if (result.contactActions.isNotEmpty) {
      await showModalBottomSheet<void>(
        context: context,
        builder: (sheetContext) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final action in result.contactActions)
              ListTile(
                  title: Text(action.title),
                  leading: Icon(action.icon),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_openResult(action));
                  }),
          ]),
        ),
      );
      return;
    }
    if (result.contactPhone != null) {
      await _rememberContactSelection(result);
    }
    await _saveToHistory(result);
    unawaited(_recordKnowledgeUsage(result));
    switch (result.kind) {
      case ResultKind.app:
        await _openApp(result.packageName);
        break;
      case ResultKind.document:
        if (result.documentId != null && !result.localOriginalAvailable) {
          _showMessage(
            'This result is available in your cloud index, but the original file is not available on this device.',
          );
          break;
        }
        await _openDocument(
          result.path,
          mimeType: result.mimeType,
          name: result.title,
          expectedFileSize: result.expectedFileSize,
          expectedModifiedSeconds: result.expectedModifiedSeconds,
        );
        break;
      case ResultKind.action:
        if (result.url?.scheme == 'tel') {
          await _makeCall(result.url!.path);
        } else if (result.url?.scheme == 'music') {
          await _playMusic(
            result.url!.queryParameters['q'] ?? '',
            result.url!.host,
          );
        } else if (result.url?.scheme == 'whatsapp') {
          final phone = result.url!.queryParameters['phone'];
          if (phone != null) {
            await _openWhatsApp(
              phone,
              message: result.url!.queryParameters['text'] ?? '',
            );
          } else {
            await _openUrl(result.url);
          }
        } else {
          await _openUrl(result.url);
        }
        break;
      case ResultKind.web:
        if (result.webSearchQuery != null) {
          if (!mounted) return;
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => GoogleSearchBrowserPage(
                query: result.webSearchQuery!,
              ),
            ),
          );
        } else {
          await _openUrl(result.url);
        }
        break;
    }
  }

  Future<void> _recordKnowledgeUsage(SearchResult result) async {
    final target = result.path ??
        result.packageName ??
        result.url?.toString() ??
        result.contactPhone ??
        result.title;
    try {
      await searchPlatformChannel.invokeMethod<bool>('recordKnowledgeUsage', {
        'kind': result.kind.name,
        'target': target,
        'title': result.title,
      });
    } catch (_) {
      // Personal relevance remains optional on unsupported platforms.
    }
  }

  Future<void> _makeCall(String phoneNumber) async {
    try {
      await searchPlatformChannel
          .invokeMethod('makeDirectCall', {'phone': phoneNumber});
    } on PlatformException catch (error) {
      _showMessage(
        error.code == 'PERMISSION_DENIED'
            ? 'Allow Phone permission to place calls directly.'
            : 'Could not place this call directly.',
      );
    } catch (_) {
      _showMessage('Could not place this call directly.');
    }
  }

  Future<void> _openWhatsApp(String phone, {String message = ''}) async {
    try {
      await searchPlatformChannel.invokeMethod('openWhatsApp', {
        'phone': phone,
        'message': message,
      });
    } catch (_) {
      await _openUrl(Uri(
        scheme: 'whatsapp',
        host: 'send',
        queryParameters: {
          'phone': phone,
          if (message.isNotEmpty) 'text': message,
        },
      ));
    }
  }

  Future<void> _playMusic(String query, String provider) async {
    try {
      await searchPlatformChannel.invokeMethod('playMusic', {
        'query': query,
        'provider': provider,
      });
    } catch (_) {
      await _openUrl(provider == 'spotify'
          ? Uri.https('open.spotify.com', '/search/$query')
          : Uri.https('music.apple.com', '/us/search', {'term': query}));
    }
  }

  Future<void> _openApp(String? packageName) async {
    if (packageName == null) return;

    try {
      await searchPlatformChannel
          .invokeMethod('openApp', {'package': packageName});
    } catch (_) {
      _showMessage('Could not open this app on this device.');
    }
  }

  Future<void> _searchInApp(String? packageName, String query) async {
    if (packageName == null || query.trim().isEmpty) return;
    try {
      await searchPlatformChannel.invokeMethod('searchInApp', {
        'package': packageName,
        'query': query,
      });
    } on PlatformException catch (error) {
      if (error.code == 'ACCESSIBILITY_DISABLED') {
        _showMessage(
            'Enable App automation in Settings before using this command.');
      } else {
        _showMessage('Could not search in that app.');
      }
    } catch (_) {
      _showMessage('Could not search in that app.');
    }
  }

  Future<void> _openDocument(
    String? path, {
    String? mimeType,
    String? name,
    int? expectedFileSize,
    int? expectedModifiedSeconds,
  }) async {
    if (path == null || path.isEmpty) {
      _showMessage('This sample document is indexed for search only.');
      return;
    }

    final shouldPreserveSearch =
        _query.trim().isNotEmpty && _results.isNotEmpty;
    if (shouldPreserveSearch) _preserveSearchOnNextResume = true;
    try {
      await searchPlatformChannel.invokeMethod('openDocument', {
        'path': path,
        'mimeType': mimeType,
        'name': name,
        'expectedFileSize': expectedFileSize,
        'expectedModifiedSeconds': expectedModifiedSeconds,
      });
    } on PlatformException catch (error) {
      _preserveSearchOnNextResume = false;
      if (error.code == 'MISSING' || error.code == 'STALE') {
        _showMessage(
          'This result is available in your cloud index, but the original file is not available on this device.',
        );
        return;
      }
      if (error.code == 'NO_COMPATIBLE_APP') {
        await _showDocumentAppSuggestion(
          mimeType: mimeType,
          name: name,
        );
        return;
      }
      _showMessage('Could not open this document on this device.');
    } catch (_) {
      _preserveSearchOnNextResume = false;
      _showMessage('Could not open this document on this device.');
    }
  }

  String _documentAppSearchTerm(String? mimeType, String? name) {
    final type = (mimeType ?? '').toLowerCase();
    final extension = (name ?? '').split('.').last.toLowerCase();
    if (type.contains('pdf') || extension == 'pdf') return 'PDF reader';
    if (type.contains('spreadsheet') ||
        type.contains('excel') ||
        const {'xls', 'xlsx', 'csv'}.contains(extension)) {
      return 'spreadsheet viewer';
    }
    if (type.contains('presentation') ||
        const {'ppt', 'pptx'}.contains(extension)) {
      return 'presentation viewer';
    }
    if (type.contains('word') ||
        type.contains('document') ||
        const {'doc', 'docx', 'rtf'}.contains(extension)) {
      return 'document viewer';
    }
    if (type.startsWith('image/')) return 'image viewer';
    if (type.startsWith('text/') ||
        const {'txt', 'md', 'json', 'xml'}.contains(extension)) {
      return 'text editor';
    }
    return 'file viewer';
  }

  Future<void> _showDocumentAppSuggestion({
    String? mimeType,
    String? name,
  }) async {
    if (!mounted) return;
    final appType = _documentAppSearchTerm(mimeType, name);
    final shouldFindApp = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('No compatible app found'),
        content: Text(
          'No installed app can open ${name?.trim().isNotEmpty == true ? name : 'this file'}. '
          'Download a $appType, then try again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Find an app'),
          ),
        ],
      ),
    );
    if (shouldFindApp == true) {
      await _openUrl(
        Uri.https('play.google.com', '/store/search/', {'q': appType}),
      );
    }
  }

  Future<void> _openUrl(Uri? url) async {
    if (url == null) return;

    final launched = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!launched) {
      _showMessage('No app is available to open this action.');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _showSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (settingsContext) => SettingsScreen(
          themeMode: widget.themeMode,
          accountSync: widget.accountSync,
          documentIndexModeLabel: () => _documentIndexModeLabel,
          documentIndexScheduleLabel: () => _documentIndexScheduleLabel,
          documentIndexState: () => _documentIndexState,
          contactsAvailable: !_contactsPermissionDenied,
          onAccount: () => _showAccountSettings(settingsContext),
          onAppearance: () => _showAppearanceSettings(settingsContext),
          onIndexing: () => _showIndexingSettings(settingsContext),
          onClearHistory: _clearAllHistory,
          onGeminiSettings: widget.onGeminiSettings,
          onOpenAccessibility: () async {
            try {
              await searchPlatformChannel
                  .invokeMethod('openAccessibilitySettings');
            } catch (_) {
              _showMessage('Could not open Android accessibility settings.');
            }
          },
        ),
      ),
    );
  }

  void _showAccountSettings(BuildContext context) {
    final accountSync = widget.accountSync;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        if (accountSync == null) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Account backup is not configured in this build. Add the Firebase '
              'build configuration described in README.md, then rebuild.',
            ),
          );
        }
        return StreamBuilder(
          stream: accountSync.authStateChanges,
          builder: (context, snapshot) {
            final user = snapshot.data;
            final signedIn = user != null;
            return Padding(
              padding: EdgeInsets.fromLTRB(
                24,
                24,
                24,
                24 + MediaQuery.viewPaddingOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Account backup',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(signedIn
                      ? 'Signed in as ${user.email ?? user.displayName ?? 'Google user'}'
                      : 'Sign in to restore your appearance preference on a new phone.'),
                  const SizedBox(height: 8),
                  const Text(
                    'For privacy, search history, contacts, installed apps, and documents '
                    'are never uploaded.',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 20),
                  if (signedIn)
                    FilledButton.icon(
                      icon: const Icon(Icons.logout),
                      label: const Text('Sign out'),
                      onPressed: () async {
                        try {
                          await accountSync.signOut();
                        } catch (_) {
                          if (mounted) {
                            _showMessage('Sign-out could not be completed.');
                          }
                        }
                      },
                    )
                  else ...[
                    FilledButton.icon(
                      icon: const Icon(Icons.g_mobiledata_rounded, size: 28),
                      label: const Text('Continue with Google'),
                      onPressed: () async {
                        try {
                          final user = await accountSync.signInWithGoogle();
                          if (user != null) await widget.onSignedIn();
                        } catch (error) {
                          if (mounted) {
                            _showMessage(AccountSync.signInErrorMessage(error));
                          }
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.apple_rounded),
                      label: const Text('Continue with Apple'),
                      onPressed: () async {
                        try {
                          final user = await accountSync.signInWithApple();
                          if (user != null) await widget.onSignedIn();
                        } catch (_) {
                          if (mounted) {
                            _showMessage(
                                'Apple sign-in could not be completed.');
                          }
                        }
                      },
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showAppearanceSettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          return Container(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Appearance',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                RadioGroup<ThemeMode>(
                  groupValue: widget.themeMode,
                  onChanged: (value) {
                    if (value == null) return;
                    widget.onSetThemeMode(value);
                    Navigator.pop(context);
                  },
                  child: const Column(
                    children: [
                      RadioListTile<ThemeMode>(
                        title: Text('Light Mode'),
                        value: ThemeMode.light,
                        activeColor: Color(0xFF4CAF50),
                      ),
                      RadioListTile<ThemeMode>(
                        title: Text('Dark Mode'),
                        value: ThemeMode.dark,
                        activeColor: Color(0xFF4CAF50),
                      ),
                      RadioListTile<ThemeMode>(
                        title: Text('System Default'),
                        value: ThemeMode.system,
                        activeColor: Color(0xFF4CAF50),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _showIndexingSettings(BuildContext settingsContext) async {
    var selectedMode = _documentIndexMode;
    var saving = false;
    String? feedback;

    Future<void> chooseScanSchedule(
      BuildContext sheetContext,
      StateSetter setSheetState,
    ) async {
      final selected = await showTimePicker(
        context: sheetContext,
        helpText: 'Choose scan start time',
        initialTime: TimeOfDay(
          hour: _documentIndexScheduleStartMinute ~/ 60,
          minute: _documentIndexScheduleStartMinute % 60,
        ),
      );
      if (selected == null) return;
      final startMinute = selected.hour * 60 + selected.minute;
      final endMinute = (startMinute + 7 * 60) % (24 * 60);
      setSheetState(() {
        saving = true;
        feedback = null;
      });
      final saved = await _setDocumentIndexSchedule(
        startMinute: startMinute,
        endMinute: endMinute,
      );
      if (!sheetContext.mounted) return;
      setSheetState(() {
        saving = false;
        if (saved) feedback = 'Scan schedule saved.';
      });
    }

    await showModalBottomSheet<void>(
      context: settingsContext,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetBuildContext, setSheetState) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              12,
              20,
              12,
              20 + MediaQuery.viewPaddingOf(sheetContext).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'File indexing',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Choose how much of the phone Apex AI may use. Higher speeds finish sooner but use more battery, CPU, and memory.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                const SizedBox(height: 8),
                RadioGroup<String>(
                  groupValue: selectedMode,
                  onChanged: (mode) {
                    if (saving || mode == null || mode == selectedMode) return;
                    setSheetState(() {
                      selectedMode = mode;
                      saving = true;
                      feedback = null;
                    });
                    unawaited(_setDocumentIndexMode(mode).then((saved) {
                      if (!sheetContext.mounted) return;
                      setSheetState(() {
                        saving = false;
                        if (!saved) selectedMode = _documentIndexMode;
                        if (saved) feedback = 'Indexing preference saved.';
                      });
                    }));
                  },
                  child: const Column(
                    children: [
                      RadioListTile<String>(
                        value: 'ultra_fast',
                        title: Text('Ultra fast'),
                        subtitle: Text(
                          'Maximum throughput with the largest continuous batches. Runs heavy files at any time and may heat the phone, drain battery, or slow other apps.',
                        ),
                      ),
                      RadioListTile<String>(
                        value: 'fast',
                        title: Text('Fast'),
                        subtitle: Text(
                          'Large, frequent batches whenever the battery is healthy. PDF, image, and OCR work can run outside the chosen schedule.',
                        ),
                      ),
                      RadioListTile<String>(
                        value: 'balanced',
                        title: Text('Balanced'),
                        subtitle: Text(
                          'Small files run gently. Heavy PDF, image, and OCR work uses the chosen schedule while charging and idle.',
                        ),
                      ),
                      RadioListTile<String>(
                        value: 'slow',
                        title: Text('Slow'),
                        subtitle: Text(
                          'Lowest impact: one file at a time, only during the chosen schedule while charging and idle, with long pauses between batches.',
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.schedule_outlined),
                  title: const Text('Scan schedule'),
                  subtitle: Text(
                    '$_documentIndexScheduleLabel daily. Balanced uses it for heavy files; Slow uses it for all files. Fast and Ultra fast may continue outside it.',
                  ),
                  trailing: TextButton(
                    onPressed: saving
                        ? null
                        : () => unawaited(
                              chooseScanSchedule(sheetContext, setSheetState),
                            ),
                    child: const Text('Choose time'),
                  ),
                  onTap: saving
                      ? null
                      : () => unawaited(
                            chooseScanSchedule(sheetContext, setSheetState),
                          ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: saving
                          ? null
                          : () async {
                              setSheetState(() {
                                saving = true;
                                feedback = null;
                              });
                              final restarted =
                                  await _confirmRestartDocumentIndex(
                                sheetContext,
                              );
                              if (!sheetContext.mounted) return;
                              setSheetState(() => saving = false);
                              if (restarted) Navigator.pop(sheetContext);
                            },
                      icon: const Icon(Icons.restart_alt_rounded),
                      label: const Text('Restart scan from beginning'),
                    ),
                  ),
                ),
                if (saving) const LinearProgressIndicator(),
                if (feedback != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 2),
                    child: Text(
                      feedback!,
                      style: TextStyle(
                        color: Theme.of(sheetBuildContext).colorScheme.primary,
                      ),
                    ),
                  ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.folder_off_outlined),
                  title: const Text('Folder privacy'),
                  subtitle: const Text(
                    'Choose folders that Apex AI must never index.',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: saving
                      ? null
                      : () {
                          Navigator.pop(sheetContext);
                          unawaited(_showFolderPrivacy(settingsContext));
                        },
                ),
                FutureBuilder<Map<dynamic, dynamic>?>(
                  future:
                      searchPlatformChannel.invokeMethod<Map<dynamic, dynamic>>(
                    'getKnowledgeStatus',
                  ),
                  builder: (context, snapshot) {
                    final status = snapshot.data;
                    final subtitle = status == null
                        ? 'Preparing private relationship index…'
                        : '${status['files'] ?? 0} files • '
                            '${status['entities'] ?? 0} topics • '
                            '${status['relations'] ?? 0} relationships';
                    Future<void> resetKnowledge() async {
                      final reset =
                          await _confirmClearKnowledgeIndex(sheetContext);
                      if (reset && sheetContext.mounted) {
                        setSheetState(() {
                          feedback = 'Personal knowledge reset.';
                        });
                      }
                    }

                    return ListTile(
                      leading: const Icon(Icons.hub_outlined),
                      title: const Text('Personal knowledge graph'),
                      subtitle: Text(subtitle),
                      onTap: saving ? null : resetKnowledge,
                      trailing: TextButton(
                        onPressed: saving ? null : resetKnowledge,
                        child: const Text('Reset'),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showFolderPrivacy(BuildContext context) async {
    List<String> folders = const [];
    Set<String> excluded = <String>{};
    try {
      final values = await Future.wait<dynamic>([
        searchPlatformChannel.invokeMethod<List<dynamic>>('getDocumentFolders'),
        searchPlatformChannel.invokeMethod<List<dynamic>>('getExcludedFolders'),
      ]);
      folders = (values[0] as List? ?? const [])
          .map((item) => '$item')
          .where((item) => item.trim().isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      excluded =
          (values[1] as List? ?? const []).map((item) => '$item').toSet();
    } catch (_) {
      if (mounted) {
        _showMessage('Folder privacy is unavailable on this device.');
      }
      return;
    }
    if (!mounted || !context.mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.72,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 22, 24, 6),
                  child: Text(
                    'Folder privacy',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 0, 24, 14),
                  child: Text(
                    'Turn a folder off to remove it from local search and the personal knowledge graph.',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: folders.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'No shared-storage folders are available yet.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: folders.length,
                          itemBuilder: (context, index) {
                            final folder = folders[index];
                            final isIncluded = !excluded.contains(folder);
                            return CheckboxListTile(
                              value: isIncluded,
                              secondary: const Icon(Icons.folder_outlined),
                              title: Text(
                                folder,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                isIncluded ? 'Indexed locally' : 'Excluded',
                              ),
                              onChanged: (value) async {
                                final include = value == true;
                                setSheetState(() {
                                  if (include) {
                                    excluded.remove(folder);
                                  } else {
                                    excluded.add(folder);
                                  }
                                });
                                try {
                                  await searchPlatformChannel
                                      .invokeMethod<bool>(
                                    'setFolderExcluded',
                                    {'folder': folder, 'excluded': !include},
                                  );
                                } catch (_) {
                                  setSheetState(() {
                                    if (include) {
                                      excluded.add(folder);
                                    } else {
                                      excluded.remove(folder);
                                    }
                                  });
                                  if (mounted) {
                                    _showMessage(
                                      'Could not update folder privacy.',
                                    );
                                  }
                                }
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmRestartDocumentIndex(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restart the file scan?'),
        content: const Text(
          'Apex AI will rebuild its private file index from the beginning. '
          'Your files stay untouched, while existing search results refresh gradually.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Restart scan'),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    final restarted = await _restartDocumentIndexing();
    if (restarted) {
      _showMessage('Fresh file scan started. Results will refresh gradually.');
    }
    return restarted;
  }

  Future<bool> _confirmClearKnowledgeIndex(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset personal knowledge?'),
        content: const Text(
          'This removes learned file relationships and usage signals. '
          'The private index will rebuild gradually from files on this phone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    try {
      final cleared =
          await searchPlatformChannel.invokeMethod<bool>('clearKnowledgeIndex');
      if (cleared != true) {
        _showMessage('Could not reset personal knowledge.');
        return false;
      }
      return true;
    } catch (_) {
      _showMessage('Could not reset personal knowledge.');
      return false;
    }
  }

  void _clearSearch() {
    _controller.clear();
    _quickSearchHint = null;
    _resultFilter = 'All';
    _handleQueryInput('');
  }

  Future<void> _showScopePicker() async {
    final selection = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Choose context',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 6),
                const Text(
                  'Apex AI searches only the sources you select.',
                  style: TextStyle(color: NexaColors.textSecondary),
                ),
                const SizedBox(height: 14),
                SearchScopeOption(
                  icon: Icons.search_rounded,
                  title: 'Contacts, apps & files',
                  subtitle: 'Search everything available on this device',
                  selected: _contextScope == 'Contacts, apps & files',
                  onTap: () => Navigator.pop(sheetContext, 'All'),
                ),
                SearchScopeOption(
                  icon: Icons.apps_rounded,
                  title: 'Apps on this device',
                  subtitle: 'Installed apps and supported app actions',
                  selected: _contextScope == 'Apps on this device',
                  onTap: () => Navigator.pop(sheetContext, 'Apps'),
                ),
                SearchScopeOption(
                  icon: Icons.people_alt_outlined,
                  title: 'Contacts, calls & messages',
                  subtitle: 'People and communication actions',
                  selected: _contextScope == 'Contacts, calls & messages',
                  onTap: () => Navigator.pop(sheetContext, 'People'),
                ),
                SearchScopeOption(
                  icon: Icons.description_outlined,
                  title: 'Documents & OCR',
                  subtitle: 'Filenames and text found inside documents',
                  selected: _contextScope == 'Documents & OCR',
                  onTap: () => Navigator.pop(sheetContext, 'Files'),
                ),
                SearchScopeOption(
                  icon: Icons.public_rounded,
                  title: 'Web & browser',
                  subtitle: 'Open pages and search the web',
                  selected: _contextScope == 'Web & browser',
                  onTap: () => Navigator.pop(sheetContext, 'Web'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selection == null || !mounted) return;
    setState(() {
      _resultFilter = selection;
      _contextScope = switch (selection) {
        'Apps' => 'Apps on this device',
        'People' => 'Contacts, calls & messages',
        'Files' => 'Documents & OCR',
        'Web' => 'Web & browser',
        _ => 'Contacts, apps & files',
      };
    });
    if (_query.isNotEmpty) _refreshResults(_query);
  }

  Future<void> _showAssistantTools() async {
    final selection = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
          child: SingleChildScrollView(
              child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Add context',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 14),
              SearchScopeOption(
                icon: Icons.phone_android_rounded,
                title: 'Search this device',
                subtitle: 'Apps, contacts, files, calls and messages',
                onTap: () => Navigator.pop(sheetContext, 'device'),
              ),
              SearchScopeOption(
                icon: Icons.document_scanner_outlined,
                title: 'Scan a document',
                subtitle: 'Use OCR to understand printed text',
                onTap: () => Navigator.pop(sheetContext, 'document'),
              ),
              SearchScopeOption(
                icon: Icons.upload_file_rounded,
                title: 'Import class notes',
                subtitle: 'Add Gmail attachments or files by subject',
                onTap: () => Navigator.pop(sheetContext, 'import'),
              ),
              SearchScopeOption(
                icon: Icons.public_rounded,
                title: 'Search the web',
                subtitle: 'Find current information in your browser',
                onTap: () => Navigator.pop(sheetContext, 'web'),
              ),
            ],
          )),
        ),
      ),
    );
    if (selection == null || !mounted) return;
    if (selection == 'import') {
      await _pickNotesToImport();
      return;
    }
    setState(() {
      switch (selection) {
        case 'document':
          _contextScope = 'Documents & OCR';
          _resultFilter = 'Files';
          _quickSearchHint = 'Ask about a document';
          break;
        case 'web':
          _contextScope = 'Web & browser';
          _resultFilter = 'Web';
          _quickSearchHint = 'Search the web';
          break;
        default:
          _contextScope = 'Contacts, apps & files';
          _resultFilter = 'All';
          _quickSearchHint = 'Search this device';
          break;
      }
    });
    _requestFocus();
  }

  Widget _buildNexaAssistant(BuildContext context) {
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final hasQuery = _query.isNotEmpty;
    if (_voiceConversationActive && !_voiceFollowUpMode) {
      return _buildVoiceOverlay();
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: ColoredBox(
        color: NexaColors.canvas,
        child: Stack(
          fit: StackFit.expand,
          children: [
            NexaAtmosphere(quiet: hasQuery),
            SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Column(
                    children: [
                      _buildAssistantTopBar(hasQuery: hasQuery),
                      Expanded(
                        child: hasQuery
                            ? _buildNexaResults()
                            : _buildAssistantIdleState(),
                      ),
                      if (!keyboardVisible)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                          child: _buildContextStrip(),
                        ),
                      if (!keyboardVisible && !hasQuery)
                        const SizedBox(height: 12),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          16,
                          0,
                          16,
                          keyboardVisible ? 8 : 12,
                        ),
                        child: _buildNexaComposer(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAssistantTopBar({required bool hasQuery}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      child: Row(
        children: [
          if (hasQuery)
            SearchGlassIconButton(
              tooltip: 'Clear results',
              icon: Icons.arrow_back_rounded,
              onPressed: _clearSearch,
            )
          else
            const NexaBrand(compact: true),
          const Spacer(),
          SearchGlassIconButton(
            tooltip: 'History',
            icon: Icons.history_rounded,
            onPressed: widget.onOpenHistory,
          ),
          const SizedBox(width: 8),
          SearchGlassIconButton(
            tooltip: 'Settings',
            icon: Icons.settings_rounded,
            onPressed: () => _showSettings(context),
          ),
        ],
      ),
    );
  }

  Widget _buildAssistantIdleState() {
    final isLoading = _loadingContacts || _loadingApps || _loadingDocuments;
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good morning'
        : hour < 17
            ? 'Good afternoon'
            : 'Good evening';
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxHeight < 420;
      final textScale = MediaQuery.textScalerOf(context).scale(1);
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 22, 0, 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
              minHeight: math.max(0, constraints.maxHeight - 38)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 24),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(greeting,
                          style: const TextStyle(
                              color: NexaColors.textSecondary, fontSize: 15)),
                      const SizedBox(height: 10),
                      Text('A little less effort.\nA lot more done.',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: compact ? 32 : 40,
                              height: 1.12,
                              letterSpacing: -1.5,
                              fontWeight: FontWeight.w500)),
                      const SizedBox(height: 14),
                      const Text('Find it. Say it. Make it happen.',
                          style: TextStyle(
                              color: NexaColors.textSecondary, fontSize: 14)),
                    ]),
              ),
              if (!compact)
                const Padding(
                  padding: EdgeInsets.only(right: 24),
                  child: Center(child: NexaSignal(size: 166)),
                ),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const SizedBox(height: 24),
                if (_contactsPermissionDenied)
                  SearchCompactStatusBanner(
                      icon: Icons.person_off_outlined,
                      label: 'Contacts are not available',
                      actionLabel: 'Enable',
                      onAction: _loadContacts),
                if (isLoading)
                  const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text('Preparing your private search…',
                          style: TextStyle(
                              color: NexaColors.textSecondary, fontSize: 12))),
                const Text('A PLACE TO START',
                    style: TextStyle(
                        color: NexaColors.textTertiary,
                        fontSize: 10,
                        letterSpacing: 1.8,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                SizedBox(
                  height: 156 + math.max(0, textScale - 1) * 100,
                  child: ListView(scrollDirection: Axis.horizontal, children: [
                    NexaSuggestionCard(
                        icon: Icons.description_outlined,
                        title: 'Find a file',
                        subtitle: 'Just describe it',
                        onTap: () => _startQuickSearch('Search documents')),
                    const SizedBox(width: 10),
                    NexaSuggestionCard(
                        icon: Icons.call_outlined,
                        title: 'Call someone',
                        subtitle: 'Stay connected',
                        color: NexaColors.iris,
                        onTap: () =>
                            _startQuickSearch('Who do you want to call?')),
                    const SizedBox(width: 10),
                    NexaSuggestionCard(
                        icon: Icons.music_note_outlined,
                        title: 'Play music',
                        subtitle: 'Set the mood',
                        color: NexaColors.success,
                        onTap: () =>
                            _startQuickSearch('What do you want to play?')),
                    const SizedBox(width: 24),
                  ]),
                ),
              ]),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildContextStrip() {
    final sourceReady =
        !_loadingContacts && !_loadingApps && !_loadingDocuments;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _showScopePicker,
        borderRadius: BorderRadius.circular(18),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Row(children: [
              Icon(Icons.layers_outlined,
                  size: 18,
                  color:
                      sourceReady ? NexaColors.info : NexaColors.textTertiary),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(_contextScope,
                      style: const TextStyle(
                          color: NexaColors.textSecondary, fontSize: 12))),
              const Icon(Icons.expand_more_rounded,
                  color: NexaColors.textTertiary, size: 20),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildNexaComposer() {
    final activeText = _controller.text.trim().isNotEmpty;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      constraints:
          BoxConstraints(minHeight: _voiceConversationActive ? 86 : 64),
      child: NexaLuminousBorder(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: _voiceConversationActive
              ? Row(
                  children: [
                    IconButton(
                      tooltip: 'Stop voice search',
                      onPressed: () => unawaited(_endVoiceConversation()),
                      icon:
                          const Icon(Icons.close_rounded, color: Colors.white),
                    ),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _voiceStatusMessage,
                            style: const TextStyle(
                              color: NexaColors.cyan,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _voiceTranscript.trim().isEmpty
                                ? 'Say what you need'
                                : _voiceTranscript.trim(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    SearchVoiceLevelIndicator(
                      level: _voiceLevel,
                      active: _isListening,
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: 'Finish speaking',
                      onPressed: _toggleVoiceSearch,
                      style: IconButton.styleFrom(
                        backgroundColor: NexaColors.blue,
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.mic_rounded),
                    ),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: 'Add context',
                      onPressed: _showAssistantTools,
                      icon: const Icon(Icons.add_rounded, color: Colors.white),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        autofocus: false,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.search,
                        onChanged: _handleQueryInput,
                        onSubmitted: (value) =>
                            unawaited(_submitCommand(value)),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: InputDecoration(
                          filled: false,
                          hintText: _quickSearchHint ?? 'Ask Apex AI',
                          hintStyle: const TextStyle(
                            color: NexaColors.textSecondary,
                            fontWeight: FontWeight.w500,
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 15,
                          ),
                        ),
                      ),
                    ),
                    if (activeText)
                      IconButton(
                        tooltip: 'Clear request',
                        onPressed: _clearSearch,
                        icon: const Icon(
                          Icons.close_rounded,
                          color: NexaColors.textSecondary,
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: IconButton.filled(
                        tooltip:
                            activeText ? 'Send request' : 'Start voice input',
                        onPressed: activeText
                            ? () => unawaited(_submitCommand(_controller.text))
                            : _toggleVoiceSearch,
                        style: IconButton.styleFrom(
                          backgroundColor: NexaColors.blue,
                          foregroundColor: Colors.white,
                        ),
                        icon: Icon(
                          activeText
                              ? Icons.arrow_upward_rounded
                              : Icons.mic_rounded,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  List<SearchResult> get _visibleResults {
    return _results.where((result) {
      return switch (_resultFilter) {
        'Apps' => result.kind == ResultKind.app,
        'Files' => result.kind == ResultKind.document,
        'Web' => result.kind == ResultKind.web,
        'People' => result.kind == ResultKind.action &&
            (result.contactPhone != null ||
                result.title.startsWith('Call ') ||
                result.title.startsWith('Message ') ||
                result.title.startsWith('WhatsApp ')),
        _ => true,
      };
    }).toList();
  }

  Widget _buildNexaResults() {
    final visible = _visibleResults;
    final documentQuery = _resolveKnowledgeQuery(
      _activeIntent.type == UniversalIntentType.searchDocuments
          ? _activeIntent.target
          : _query,
    );
    final searchingFiles =
        _rankingBusy || _nativeDocumentSearchInFlight || _cloudSearchInFlight;
    KnowledgeConversationTurn? activeConversationTurn;
    for (final turn in _conversationTurns) {
      if (turn.id == _activeConversationTurnId) {
        activeConversationTurn = turn;
        break;
      }
    }
    final showingSubmittedTurn = activeConversationTurn != null &&
        activeConversationTurn.query.trim() == _query.trim();
    final showingConversation = showingSubmittedTurn &&
        _activeIntent.type == UniversalIntentType.unknown;
    final knowledgeAnswer =
        showingConversation ? _composeKnowledgeAnswer(documentQuery) : null;
    final previousTurns = showingConversation && widget.onAskAi == null
        ? (_conversationTurns
            .where((turn) =>
                turn.answer != null && turn.id != _activeConversationTurnId)
            .toList()
            .reversed
            .take(2)
            .toList()
            .reversed)
        : const <KnowledgeConversationTurn>[];
    final groups = <String, List<SearchResult>>{};
    for (final result in visible) {
      const group = '';
      groups.putIfAbsent(group, () => <SearchResult>[]).add(result);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Apex AI',
                        style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 2),
                    Text(
                      'On-device search • ${visible.length} results',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: NexaColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.onAskAi != null)
                IconButton(
                    tooltip: 'Ask Gemini in a new chat',
                    onPressed: () => widget.onAskAi!(_query),
                    icon: const Icon(Icons.auto_awesome_outlined)),
            ],
          ),
        ),
        SizedBox(
          height: 42,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            scrollDirection: Axis.horizontal,
            itemCount: const ['All', 'Apps', 'Files', 'People', 'Web'].length,
            separatorBuilder: (_, __) => const SizedBox(width: 7),
            itemBuilder: (context, index) {
              final filter =
                  const ['All', 'Apps', 'Files', 'People', 'Web'][index];
              return ChoiceChip(
                selected: _resultFilter == filter,
                label: Text(filter),
                onSelected: (_) => setState(() {
                  _resultFilter = filter;
                  _contextScope = switch (filter) {
                    'Apps' => 'Apps on this device',
                    'Files' => 'Documents & OCR',
                    'People' => 'Contacts, calls & messages',
                    'Web' => 'Web & browser',
                    _ => 'Contacts, apps & files',
                  };
                }),
              );
            },
          ),
        ),
        SizedBox(
          height: 40,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _deferredResults != null
                ? TextButton(
                    onPressed: () {
                      setState(() {
                        _results = _deferredResults!;
                        _deferredResults = null;
                        _readingResultsQuery = null;
                      });
                      if (_resultsScrollController.hasClients) {
                        _resultsScrollController.jumpTo(0);
                      }
                    },
                    child: const Text('Show updated results'),
                  )
                : Align(
                    alignment: Alignment.centerLeft,
                    child: Text(_cloudSearchOffline && visible.isNotEmpty
                        ? 'Offline • showing results available on this device'
                        : searchingFiles
                            ? 'Searching files…'
                            : _rankedDocumentQuery == documentQuery &&
                                    visible.isNotEmpty &&
                                    visible
                                        .every((r) => r.kind == ResultKind.web)
                                ? 'No matching local results found.'
                                : ''),
                  ),
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? SearchNoResults(
                  query: _query,
                  onReset: () {
                    setState(() {
                      _resultFilter = 'All';
                      _contextScope = 'Contacts, apps & files';
                    });
                  })
              : NotificationListener<ScrollStartNotification>(
                  onNotification: (notification) {
                    if (notification.dragDetails != null) {
                      _readingResultsQuery = _query;
                    }
                    return false;
                  },
                  child: CustomScrollView(
                    controller: _resultsScrollController,
                    slivers: [
                      for (final turn in previousTurns) ...[
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                          sliver: SliverToBoxAdapter(
                            child:
                                SearchConversationQuestion(query: turn.query),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                          sliver: SliverToBoxAdapter(
                            child:
                                SearchKnowledgeAnswerCard(answer: turn.answer!),
                          ),
                        ),
                      ],
                      if (showingConversation)
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
                          sliver: SliverToBoxAdapter(
                            child: SearchConversationQuestion(query: _query),
                          ),
                        ),
                      if (knowledgeAnswer != null)
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                          sliver: SliverToBoxAdapter(
                            child: SearchKnowledgeAnswerCard(
                              answer: knowledgeAnswer,
                            ),
                          ),
                        ),
                      if (_activeIntent.isExplicit)
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
                          sliver: SliverToBoxAdapter(
                            child: SearchUnderstoodCommandCard(
                              intent: _activeIntent,
                              contactMatchCount: _isContactIntent(_activeIntent)
                                  ? _activeContactMatches.length
                                  : 0,
                            ),
                          ),
                        ),
                      for (final entry in groups.entries) ...[
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 7),
                          sliver: SliverToBoxAdapter(
                            child: const SizedBox.shrink(),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final result = entry.value[index];
                                final first = index == 0;
                                final last = index == entry.value.length - 1;
                                return DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: NexaColors.raised,
                                    borderRadius: BorderRadius.vertical(
                                      top: first
                                          ? const Radius.circular(20)
                                          : Radius.zero,
                                      bottom: last
                                          ? const Radius.circular(20)
                                          : Radius.zero,
                                    ),
                                    border: Border(
                                      left: const BorderSide(
                                        color: Color(0x14FFFFFF),
                                      ),
                                      right: const BorderSide(
                                        color: Color(0x14FFFFFF),
                                      ),
                                      top: first
                                          ? const BorderSide(
                                              color: Color(0x14FFFFFF),
                                            )
                                          : BorderSide.none,
                                      bottom: last
                                          ? const BorderSide(
                                              color: Color(0x14FFFFFF),
                                            )
                                          : BorderSide.none,
                                    ),
                                  ),
                                  child: SearchResultCard(
                                    result: result,
                                    onTap: () => _openResult(result),
                                    onArtworkNeeded: () =>
                                        _queueResultArtwork([result]),
                                    onContactAction: _openResult,
                                    onLongPress: result.kind ==
                                            ResultKind.document
                                        ? () => _showDocumentFeedback(result)
                                        : null,
                                  ),
                                );
                              },
                              childCount: entry.value.length,
                            ),
                          ),
                        ),
                        const SliverToBoxAdapter(child: SizedBox(height: 14)),
                      ],
                      const SliverToBoxAdapter(child: SizedBox(height: 24)),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => NexaVisualEffects(
        enabled: _startupEffectsReady,
        child: _buildNexaAssistant(context),
      );

  // Kept temporarily as a reference while the Context Lens surface replaces
  // the previous dashboard-style search layout.
  Widget _buildVoiceOverlay() {
    final transcript = _voiceTranscript.trim();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_endVoiceConversation());
      },
      child: Stack(fit: StackFit.expand, children: [
        const NexaAtmosphere(),
        SafeArea(
            child: Center(
                child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(children: [
            Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 12, 8),
                child: Row(children: [
                  const Icon(Icons.graphic_eq_rounded,
                      color: NexaColors.info, size: 20),
                  const SizedBox(width: 10),
                  const Text('Apex Voice',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(
                      tooltip: 'Stop voice search',
                      onPressed: () => unawaited(_endVoiceConversation()),
                      icon: const Icon(Icons.close_rounded,
                          color: NexaColors.textSecondary)),
                ])),
            Expanded(
                child: SingleChildScrollView(
              reverse: true,
              padding: const EdgeInsets.fromLTRB(28, 36, 28, 24),
              child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                      transcript.isEmpty
                          ? 'What can I help\nyou with?'
                          : transcript,
                      style: TextStyle(
                          color: transcript.isEmpty
                              ? NexaColors.textSecondary
                              : Colors.white,
                          fontSize: 32,
                          height: 1.24,
                          letterSpacing: -0.8,
                          fontWeight: FontWeight.w400))),
            )),
            Semantics(
                liveRegion: true,
                child: Text(_voiceStatusMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: NexaColors.textSecondary, fontSize: 13))),
            AnimatedBuilder(
                animation: _voicePulseController,
                builder: (context, _) => NexaSignal(
                    size: 156,
                    phase: reduceMotion ? 0 : _voicePulseController.value,
                    level: reduceMotion ? 0 : (_voiceLevel / 10).clamp(0, 1))),
            Padding(
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
                child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                          tooltip: 'Switch to typing',
                          onPressed: () async {
                            await _endVoiceConversation();
                            if (mounted) _requestFocus();
                          },
                          icon: const Icon(Icons.keyboard_outlined,
                              color: NexaColors.textSecondary)),
                      Column(mainAxisSize: MainAxisSize.min, children: [
                        IconButton.filled(
                            tooltip: 'Finish speaking',
                            onPressed: _toggleVoiceSearch,
                            style: IconButton.styleFrom(
                                backgroundColor: NexaColors.blue,
                                foregroundColor: Colors.white,
                                minimumSize: const Size.square(64)),
                            icon: Icon(
                                _isListening
                                    ? Icons.mic_rounded
                                    : Icons.stop_rounded,
                                size: 28)),
                        const SizedBox(height: 10),
                        Text(_isListening ? 'Tap to finish' : 'Tap to stop',
                            style: const TextStyle(
                                color: NexaColors.textTertiary, fontSize: 11)),
                      ]),
                      IconButton(
                          tooltip: 'Cancel voice input',
                          onPressed: () => unawaited(_endVoiceConversation()),
                          icon: const Icon(Icons.close_rounded,
                              color: NexaColors.textSecondary)),
                    ])),
          ]),
        ))),
      ]),
    );
  }
}
