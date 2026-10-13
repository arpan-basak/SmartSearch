/// Persistent storage identifiers, shared across feature boundaries.
///
/// Existing spellings (including legacy Nexa names) are data contracts. Rename
/// the Dart symbol freely, but change a stored value only with a migration.
abstract final class PreferenceKeys {
  static const accountWelcomeSeen = 'account_welcome_seen';
  static const onboardingComplete = 'nexa_onboarding_complete';
  static const themeMode = 'theme_mode';
  static const spokenResponses = 'nexa_spoken_responses';
  static const continuousVoice = 'apex_continuous_voice';
  static const requireWakePhrase = 'apex_require_wake_phrase';
  static const contextSuggestions = 'nexa_context_suggestions';
  static const completionNotifications = 'nexa_completion_notifications';
  static const appLock = 'nexa_app_lock';
  static const localConversation = 'nexa_local_conversation_v1';
  static const contactChoiceAliases = 'contact_choice_aliases';
  static const contactSelectionStats = 'contact_selection_stats';
  static const documentSearchFeedback = 'document_search_feedback';
  static const legacyManualGroups = 'manual_whatsapp_groups';
  static const legacyManualGroupLinks = 'manual_whatsapp_group_links';
  static const cloudIndexSettings = 'apex_cloud_index_settings_v1';
  static const cloudDocumentLocators = 'apex_cloud_document_locators_v1';
  static const cloudSyncManifest = 'apex_cloud_sync_manifest_v1';
  static const cloudDeviceId = 'apex_cloud_device_id_v1';
}
