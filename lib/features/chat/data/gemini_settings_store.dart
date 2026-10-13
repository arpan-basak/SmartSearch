import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class GeminiSettings {
  const GeminiSettings({this.apiKey = '', this.model = defaultModel});
  static const defaultModel = 'gemini-3.5-flash-lite';
  static const models = {
    'gemini-3.5-flash-lite': 'Gemini 3.5 Flash-Lite · economical',
    'gemini-3.8-flash': 'Gemini 3.8 Flash · advanced',
    'gemini-2.5-flash': 'Gemini 2.5 Flash · legacy access',
  };
  final String apiKey;
  final String model;
  bool get configured => apiKey.trim().isNotEmpty;
}

abstract interface class GeminiSettingsStore {
  Future<GeminiSettings> read();
  Future<void> write(GeminiSettings settings);
  Future<void> remove();
}

class SecureGeminiSettingsStore implements GeminiSettingsStore {
  const SecureGeminiSettingsStore(
      {FlutterSecureStorage storage = const FlutterSecureStorage()})
      : _storage = storage;
  final FlutterSecureStorage _storage;
  static const storageKey = 'apex_gemini_configuration_v1';

  @override
  Future<GeminiSettings> read() async {
    final value = await _storage.read(key: storageKey);
    if (value == null) return const GeminiSettings();
    final json = jsonDecode(value) as Map<String, dynamic>;
    return GeminiSettings(
        apiKey: json['apiKey'] as String, model: json['model'] as String);
  }

  @override
  Future<void> write(GeminiSettings settings) => _storage.write(
      key: storageKey,
      value: jsonEncode(
          {'apiKey': settings.apiKey.trim(), 'model': settings.model}));

  @override
  Future<void> remove() => _storage.delete(key: storageKey);
}
