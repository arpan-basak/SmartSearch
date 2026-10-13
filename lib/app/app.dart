import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_search_app/core/storage/preference_keys.dart';
import 'package:smart_search_app/design_system/nexa_theme.dart';
import 'package:smart_search_app/features/account/data/account_sync.dart';
import 'package:smart_search_app/features/account/presentation/account_welcome_screen.dart';
import 'package:smart_search_app/features/chat/application/chat_controller.dart';
import 'package:smart_search_app/features/chat/domain/chat_models.dart';
import 'package:smart_search_app/features/chat/presentation/chat_list_screen.dart';
import 'package:smart_search_app/features/chat/presentation/chat_screen.dart';
import 'package:smart_search_app/features/chat/presentation/gemini_settings_screen.dart';
import 'package:smart_search_app/features/history/presentation/history_screen.dart';
import 'package:smart_search_app/features/onboarding/presentation/nexa_onboarding.dart';
import 'package:smart_search_app/features/search/models/search_result.dart';
import 'package:smart_search_app/features/search/presentation/search_screen.dart';

class SmartSearchApp extends StatefulWidget {
  const SmartSearchApp({
    super.key,
    this.accountSync,
    this.enableOnboarding = false,
    this.chatController,
  });

  final AccountSync? accountSync;
  final bool enableOnboarding;
  final ChatController? chatController;

  @override
  State<SmartSearchApp> createState() => _SmartSearchAppState();
}

class _SmartSearchAppState extends State<SmartSearchApp> {
  ThemeMode _themeMode = ThemeMode.dark;
  int _currentIndex = 0;
  List<SearchResult> _history = const [];
  bool _showAccountWelcome = false;
  bool _showOnboarding = false;
  bool _accountWelcomeDismissed = false;
  final _navigator = GlobalKey<NavigatorState>();
  late final ChatController _chats;
  bool _chatsVisited = false;
  bool _creatingChat = false;

  @override
  void initState() {
    super.initState();
    // No I/O during construction. History loads lazily after a visible frame.
    _chats = widget.chatController ?? ChatController.device();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
      if (!mounted) return;
      unawaited(_loadTheme());
      unawaited(_loadAccountWelcome());
    });
  }

  Future<void> _loadAccountWelcome() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || _accountWelcomeDismissed) return;
    final hasSeenWelcome =
        prefs.getBool(PreferenceKeys.accountWelcomeSeen) ?? false;
    final hasCompletedOnboarding =
        prefs.getBool(PreferenceKeys.onboardingComplete) ?? false;
    setState(() {
      _showAccountWelcome = !hasSeenWelcome;
      _showOnboarding =
          widget.enableOnboarding && hasSeenWelcome && !hasCompletedOnboarding;
    });
  }

  Future<void> _continueWithoutAccount() async {
    _accountWelcomeDismissed = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(PreferenceKeys.accountWelcomeSeen, true);
    final hasCompletedOnboarding =
        prefs.getBool(PreferenceKeys.onboardingComplete) ?? false;
    if (mounted) {
      setState(() {
        _showAccountWelcome = false;
        _showOnboarding = widget.enableOnboarding && !hasCompletedOnboarding;
      });
    }
  }

  Future<void> _signedIn() async {
    await _restoreSyncedTheme();
    await _continueWithoutAccount();
  }

  Future<void> _completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(PreferenceKeys.onboardingComplete, true);
    if (mounted) setState(() => _showOnboarding = false);
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final themeIndex = prefs.getInt(PreferenceKeys.themeMode);
    if (themeIndex != null &&
        themeIndex >= 0 &&
        themeIndex < ThemeMode.values.length) {
      setState(() {
        _themeMode = ThemeMode.values[themeIndex];
      });
    }
  }

  bool get _isDarkMode {
    if (_themeMode == ThemeMode.system) {
      return WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark;
    }
    return _themeMode == ThemeMode.dark;
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(PreferenceKeys.themeMode, mode.index);
    setState(() {
      _themeMode = mode;
    });
    try {
      await widget.accountSync?.saveThemeMode(mode.index);
    } catch (error) {
      debugPrint('Could not sync appearance preference: $error');
    }
  }

  Future<void> _restoreSyncedTheme() async {
    try {
      final index = await widget.accountSync?.loadThemeMode();
      if (!mounted || index == null) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(PreferenceKeys.themeMode, index);
      setState(() => _themeMode = ThemeMode.values[index]);
    } catch (error) {
      debugPrint('Could not restore appearance preference: $error');
    }
  }

  // The shell routes history actions through the search feature public API.
  final _searchController = SearchScreenController();

  void _clearAllFromSearchScreen() {
    unawaited(_searchController.clearHistory());
  }

  void _openItemFromSearchScreen(SearchResult result) {
    unawaited(_searchController.openResult(result));
    setState(() => _currentIndex = 0);
  }

  void _openHistory() => setState(() => _currentIndex = 1);

  void _closeHistory() => setState(() => _currentIndex = 0);

  void _openChats() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _chatsVisited = true;
      _currentIndex = 2;
    });
  }

  Future<void> _openGeminiSettings() async {
    await _navigator.currentState!.push<void>(MaterialPageRoute(
        builder: (_) => GeminiSettingsScreen(
            store: _chats.settingsStore, gateway: _chats.gateway)));
    await _chats.refreshConfiguration();
  }

  void _openChat(ChatThread thread, {String draft = ''}) {
    _navigator.currentState!.push<void>(MaterialPageRoute(
        builder: (_) => ChatScreen(
              controller: _chats,
              threadId: thread.id,
              initialDraft: draft,
              onSettings: _openGeminiSettings,
            )));
  }

  Future<void> _newChat([String draft = '']) async {
    if (_creatingChat) return;
    _creatingChat = true;
    _openChats();
    try {
      await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
      if (!mounted) return;
      final thread = await _chats.create();
      if (mounted) _openChat(thread, draft: draft);
    } catch (_) {
      final context = _navigator.currentContext;
      if (context != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Could not create a chat. Check available storage and try again.')));
      }
    } finally {
      _creatingChat = false;
    }
  }

  @override
  void dispose() {
    if (widget.chatController == null) _chats.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final searchScreen = SearchScreen(
      controller: _searchController,
      isDarkMode: _isDarkMode,
      themeMode: _themeMode,
      onSetThemeMode: _setThemeMode,
      accountSync: widget.accountSync,
      onSignedIn: _signedIn,
      onOpenHistory: _openHistory,
      onAskAi: _newChat,
      onGeminiSettings: _openGeminiSettings,
      onHistoryChanged: (history) {
        if (mounted) setState(() => _history = List.unmodifiable(history));
      },
    );

    return MaterialApp(
      navigatorKey: _navigator,
      debugShowCheckedModeBanner: false,
      title: 'Apex AI',
      theme: NexaTheme.light(),
      darkTheme: NexaTheme.dark(),
      themeMode: _themeMode,
      home: _showAccountWelcome
          ? AccountWelcomeScreen(
              accountSync: widget.accountSync,
              onSignedIn: _signedIn,
              onContinueWithoutAccount: _continueWithoutAccount,
            )
          : _showOnboarding
              ? NexaOnboardingScreen(onComplete: _completeOnboarding)
              : Scaffold(
                  body: IndexedStack(
                    index: _currentIndex,
                    children: [
                      searchScreen,
                      HistoryScreen(
                        history: _history,
                        onClearAll: _clearAllFromSearchScreen,
                        onItemTap: _openItemFromSearchScreen,
                        onBack: _closeHistory,
                      ),
                      if (_chatsVisited)
                        ChatListScreen(
                            controller: _chats,
                            onOpen: _openChat,
                            onNew: _newChat,
                            onSettings: _openGeminiSettings)
                      else
                        const SizedBox.shrink(),
                    ],
                  ),
                  bottomNavigationBar: _currentIndex == 1
                      ? null
                      : NavigationBar(
                          selectedIndex: _currentIndex == 2 ? 1 : 0,
                          onDestinationSelected: (index) => index == 1
                              ? _openChats()
                              : setState(() => _currentIndex = 0),
                          destinations: const [
                            NavigationDestination(
                                icon: Icon(Icons.search_rounded),
                                label: 'Search'),
                            NavigationDestination(
                                icon: Icon(Icons.chat_bubble_outline_rounded),
                                selectedIcon: Icon(Icons.chat_bubble_rounded),
                                label: 'Chats'),
                          ],
                        ),
                ),
    );
  }
}
