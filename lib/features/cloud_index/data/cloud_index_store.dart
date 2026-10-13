import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_search_app/core/storage/preference_keys.dart';
import 'package:smart_search_app/features/cloud_index/domain/cloud_index_models.dart';

class CloudIndexStore {
  Future<CloudIndexSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(PreferenceKeys.cloudIndexSettings);
    if (raw == null) return const CloudIndexSettings();
    try {
      return CloudIndexSettings.fromJson(
          (jsonDecode(raw) as Map).cast<String, dynamic>());
    } catch (_) {
      return const CloudIndexSettings();
    }
  }

  Future<void> saveSettings(CloudIndexSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        PreferenceKeys.cloudIndexSettings, jsonEncode(settings.toJson()));
  }

  Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(PreferenceKeys.cloudDeviceId);
    if (existing?.isNotEmpty == true) return existing!;
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    final value = base64UrlEncode(bytes).replaceAll('=', '');
    await prefs.setString(PreferenceKeys.cloudDeviceId, value);
    return value;
  }

  Future<Map<String, CloudDocumentLocator>> loadLocators() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(PreferenceKeys.cloudDocumentLocators);
    if (raw == null) return <String, CloudDocumentLocator>{};
    try {
      final decoded = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return decoded.map((key, value) => MapEntry(
          key,
          CloudDocumentLocator.fromJson(
              (value as Map).cast<String, dynamic>())));
    } catch (_) {
      return <String, CloudDocumentLocator>{};
    }
  }

  Future<void> saveLocators(Map<String, CloudDocumentLocator> locators) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      PreferenceKeys.cloudDocumentLocators,
      jsonEncode(locators.map((key, value) => MapEntry(key, value.toJson()))),
    );
  }

  Future<Map<String, String>> loadManifest() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(PreferenceKeys.cloudSyncManifest);
    if (raw == null) return <String, String>{};
    try {
      return (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> saveManifest(Map<String, String> manifest) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        PreferenceKeys.cloudSyncManifest, jsonEncode(manifest));
  }

  Future<void> clearCloudState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(PreferenceKeys.cloudSyncManifest);
    await prefs.remove(PreferenceKeys.cloudDocumentLocators);
    await saveSettings(const CloudIndexSettings());
  }
}
