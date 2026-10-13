import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_search_app/core/storage/preference_keys.dart';
import 'package:smart_search_app/design_system/nexa_theme.dart';
import 'package:smart_search_app/features/account/data/account_sync.dart';
import 'package:smart_search_app/features/chat/data/gemini_client.dart';
import 'package:smart_search_app/features/chat/data/gemini_settings_store.dart';
import 'package:smart_search_app/features/chat/presentation/gemini_settings_screen.dart';
import 'package:smart_search_app/features/cloud_index/presentation/cloud_index_settings_screen.dart';
import 'package:smart_search_app/features/settings/presentation/scanned_files_panel.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.themeMode,
    required this.accountSync,
    required this.documentIndexModeLabel,
    required this.documentIndexScheduleLabel,
    required this.documentIndexState,
    required this.contactsAvailable,
    required this.onAccount,
    required this.onAppearance,
    required this.onIndexing,
    required this.onClearHistory,
    required this.onOpenAccessibility,
    this.onGeminiSettings,
  });

  final ThemeMode themeMode;
  final AccountSync? accountSync;
  final String Function() documentIndexModeLabel;
  final String Function() documentIndexScheduleLabel;
  final String? Function() documentIndexState;
  final bool contactsAvailable;
  final VoidCallback onAccount;
  final VoidCallback onAppearance;
  final Future<void> Function() onIndexing;
  final Future<void> Function() onClearHistory;
  final Future<void> Function() onOpenAccessibility;
  final VoidCallback? onGeminiSettings;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _spokenResponses = true;
  bool _continuousVoice = true;
  bool _requireWakePhrase = false;
  bool _contextSuggestions = true;
  bool _completionNotifications = true;
  bool _appLock = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreferences());
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _spokenResponses = prefs.getBool(PreferenceKeys.spokenResponses) ?? true;
      _continuousVoice = prefs.getBool(PreferenceKeys.continuousVoice) ?? true;
      _requireWakePhrase =
          prefs.getBool(PreferenceKeys.requireWakePhrase) ?? false;
      _contextSuggestions =
          prefs.getBool(PreferenceKeys.contextSuggestions) ?? true;
      _completionNotifications =
          prefs.getBool(PreferenceKeys.completionNotifications) ?? true;
      _appLock = prefs.getBool(PreferenceKeys.appLock) ?? false;
    });
  }

  Future<void> _setPreference(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  Future<void> _confirmClearHistory() async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 8, 22, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Clear Apex AI history?',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 10),
              const Text(
                'This removes saved searches and action receipts from this device. It cannot be undone.',
                style: TextStyle(color: NexaColors.textSecondary, height: 1.45),
              ),
              const SizedBox(height: 22),
              FilledButton(
                onPressed: () => Navigator.pop(sheetContext, true),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                  backgroundColor: NexaColors.error,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Clear history'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(sheetContext, false),
                style: TextButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true) return;
    await widget.onClearHistory();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('History cleared from this device.')),
      );
    }
  }

  String get _themeLabel => switch (widget.themeMode) {
        ThemeMode.dark => 'Dark',
        ThemeMode.light => 'Light',
        ThemeMode.system => 'Use device setting',
      };

  @override
  Widget build(BuildContext context) {
    final documentIndexState = widget.documentIndexState();
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: SafeArea(
        child: Center(
            child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            children: [
              NexaPageHeader(
                title: 'Settings',
                subtitle: 'Control how Apex AI searches and acts',
                onBack: () => Navigator.pop(context),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
                  children: [
                    _SettingsProfileRow(
                      configured: widget.accountSync != null,
                      onTap: widget.onAccount,
                    ),
                    const SizedBox(height: 28),
                    const NexaSectionLabel('AI chat'),
                    const SizedBox(height: 9),
                    _SettingsGroup(children: [
                      _SettingsRow(
                          icon: Icons.auto_awesome_outlined,
                          title: 'Gemini API',
                          subtitle: 'Add your AI Studio key and choose a model',
                          onTap: widget.onGeminiSettings ??
                              () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                      builder: (_) => GeminiSettingsScreen(
                                          store:
                                              const SecureGeminiSettingsStore(),
                                          gateway: GeminiClient())))),
                    ]),
                    const SizedBox(height: 28),
                    const NexaSectionLabel('Experience'),
                    const SizedBox(height: 9),
                    _SettingsGroup(
                      children: [
                        _SettingsRow(
                          icon: Icons.palette_outlined,
                          title: 'Appearance',
                          value: _themeLabel,
                          onTap: widget.onAppearance,
                        ),
                        _SettingsRow.switcher(
                          icon: Icons.record_voice_over_outlined,
                          title: 'Spoken responses',
                          subtitle:
                              'Read short answers aloud after voice requests',
                          value: _spokenResponses,
                          onChanged: (value) {
                            setState(() => _spokenResponses = value);
                            unawaited(_setPreference(
                                PreferenceKeys.spokenResponses, value));
                          },
                        ),
                        _SettingsRow.switcher(
                          icon: Icons.forum_outlined,
                          title: 'Voice follow-ups',
                          subtitle:
                              'Keep listening briefly so you can correct or refine a result',
                          value: _continuousVoice,
                          onChanged: (value) {
                            setState(() => _continuousVoice = value);
                            unawaited(_setPreference(
                                PreferenceKeys.continuousVoice, value));
                          },
                        ),
                        _SettingsRow.switcher(
                          icon: Icons.hearing_outlined,
                          title: 'Wake-phrase guard',
                          subtitle:
                              'Require “Apex AI” on every turn to reduce nearby-speaker activations',
                          value: _requireWakePhrase,
                          onChanged: (value) {
                            setState(() => _requireWakePhrase = value);
                            unawaited(_setPreference(
                                PreferenceKeys.requireWakePhrase, value));
                          },
                        ),
                        _SettingsRow.switcher(
                          icon: Icons.auto_awesome_outlined,
                          title: 'Context suggestions',
                          subtitle:
                              'Suggest useful next actions for the current screen',
                          value: _contextSuggestions,
                          onChanged: (value) {
                            setState(() => _contextSuggestions = value);
                            unawaited(_setPreference(
                                PreferenceKeys.contextSuggestions, value));
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 26),
                    const NexaSectionLabel('Search sources'),
                    const SizedBox(height: 9),
                    _SettingsGroup(
                      children: [
                        _SettingsRow(
                          icon: Icons.people_alt_outlined,
                          title: 'Contacts',
                          value: widget.contactsAvailable
                              ? 'Available'
                              : 'Permission off',
                          valueColor: widget.contactsAvailable
                              ? NexaColors.success
                              : NexaColors.warning,
                        ),
                        _SettingsRow(
                          icon: Icons.folder_copy_outlined,
                          title: 'Files and OCR',
                          subtitle: documentIndexState == 'complete'
                              ? 'Your local index is ready • Large files ${widget.documentIndexScheduleLabel()}'
                              : 'Indexing continues privately on this device • Large files ${widget.documentIndexScheduleLabel()}',
                          value: widget.documentIndexModeLabel(),
                          onTap: () async {
                            await widget.onIndexing();
                            if (mounted) setState(() {});
                          },
                        ),
                        const ScannedFilesPanel(),
                        _SettingsRow(
                          icon: Icons.cloud_outlined,
                          title: 'Apex Cloud Sync',
                          subtitle:
                              'Optional hybrid index • off until you consent',
                          value: 'Manage',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => CloudIndexSettingsScreen(
                                accountSync: widget.accountSync,
                              ),
                            ),
                          ),
                        ),
                        _SettingsRow(
                          icon: Icons.touch_app_outlined,
                          title: 'App automation',
                          subtitle: 'Enable only to search inside other apps',
                          value: 'Android settings',
                          onTap: widget.onOpenAccessibility,
                        ),
                      ],
                    ),
                    const SizedBox(height: 26),
                    const NexaSectionLabel('Voice and language'),
                    const SizedBox(height: 9),
                    const _SettingsGroup(
                      children: [
                        _SettingsRow(
                          icon: Icons.language_rounded,
                          title: 'Assistant language',
                          value: 'English (India)',
                        ),
                        _SettingsRow(
                          icon: Icons.mic_none_rounded,
                          title: 'Voice input',
                          value: 'Automatic',
                        ),
                      ],
                    ),
                    const SizedBox(height: 26),
                    const NexaSectionLabel('Privacy and data'),
                    const SizedBox(height: 9),
                    _SettingsGroup(
                      children: [
                        _SettingsRow.switcher(
                          icon: Icons.lock_outline_rounded,
                          title: 'App lock',
                          subtitle:
                              'Require device authentication to open history',
                          value: _appLock,
                          onChanged: (value) {
                            setState(() => _appLock = value);
                            unawaited(
                                _setPreference(PreferenceKeys.appLock, value));
                          },
                        ),
                        const _SettingsRow(
                          icon: Icons.history_toggle_off_rounded,
                          title: 'History duration',
                          value: 'Until deleted',
                        ),
                        _SettingsRow(
                          icon: Icons.delete_outline_rounded,
                          title: 'Clear history',
                          valueColor: NexaColors.error,
                          onTap: _confirmClearHistory,
                        ),
                      ],
                    ),
                    const SizedBox(height: 26),
                    const NexaSectionLabel('Shortcuts and notifications'),
                    const SizedBox(height: 9),
                    _SettingsGroup(
                      children: [
                        const _SettingsRow(
                          icon: Icons.bolt_rounded,
                          title: 'Assistant shortcuts',
                          subtitle: 'Ask Apex AI, Search device, Scan document',
                          value: '3 ready',
                        ),
                        _SettingsRow.switcher(
                          icon: Icons.notifications_none_rounded,
                          title: 'Completion notifications',
                          subtitle: 'Notify when a background action finishes',
                          value: _completionNotifications,
                          onChanged: (value) {
                            setState(() => _completionNotifications = value);
                            unawaited(_setPreference(
                                PreferenceKeys.completionNotifications, value));
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 26),
                    const NexaSectionLabel('About'),
                    const SizedBox(height: 9),
                    const _SettingsGroup(
                      children: [
                        _SettingsRow(
                          icon: Icons.help_outline_rounded,
                          title: 'Help and feedback',
                        ),
                        _SettingsRow(
                          icon: Icons.info_outline_rounded,
                          title: 'About Apex AI',
                          value: '2.0.1',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        )),
      ),
    );
  }
}

class _SettingsProfileRow extends StatelessWidget {
  const _SettingsProfileRow({required this.configured, required this.onTap});

  final bool configured;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF1D2C4A)
          : const Color(0xFFE2EAFF),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: NexaColors.blue.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(18),
                  border:
                      Border.all(color: NexaColors.info.withValues(alpha: 0.3)),
                ),
                child: Icon(Icons.person_outline_rounded,
                    color: Theme.of(context).colorScheme.primary, size: 27),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Apex AI account',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 3),
                    Text(
                      configured
                          ? 'Manage sign-in and preference sync'
                          : 'Local mode • data stays on this device',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: NexaColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? NexaColors.raised
            : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          for (var index = 0; index < children.length; index++) ...[
            children[index],
            if (index != children.length - 1)
              const Divider(indent: 62, endIndent: 14),
          ],
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.valueColor,
    this.onTap,
  })  : switchValue = null,
        onChanged = null;

  const _SettingsRow.switcher({
    required this.icon,
    required this.title,
    required bool value,
    required ValueChanged<bool> this.onChanged,
    this.subtitle,
  })  : value = null,
        valueColor = null,
        onTap = null,
        switchValue = value;

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? value;
  final Color? valueColor;
  final VoidCallback? onTap;
  final bool? switchValue;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 68),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon,
                    size: 19, color: Theme.of(context).colorScheme.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (value != null) ...[
                      const SizedBox(height: 3),
                      Text(value!,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: valueColor ??
                                      Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant)),
                    ],
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              if (switchValue != null)
                Switch(value: switchValue!, onChanged: onChanged)
              else ...[
                if (onTap != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
