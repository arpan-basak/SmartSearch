import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:smart_search_app/features/cloud_index/domain/cloud_index_models.dart';

typedef FirebaseTokenProvider = Future<String?> Function();

class CloudIndexException implements Exception {
  const CloudIndexException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class CloudIndexApi {
  CloudIndexApi({
    required this.tokenProvider,
    http.Client? client,
    String? baseUrl,
  })  : client = client ?? http.Client(),
        baseUrl = (baseUrl ?? configuredBaseUrl).replaceAll(RegExp(r'/$'), '');

  static const configuredBaseUrl =
      String.fromEnvironment('APEX_CLOUD_INDEX_URL');

  final FirebaseTokenProvider tokenProvider;
  final http.Client client;
  final String baseUrl;

  bool get isConfigured => baseUrl.startsWith('https://');

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Object? body,
  }) async {
    if (!isConfigured) {
      throw const CloudIndexException(
          'Cloud Sync is not configured in this build.');
    }
    final token = await tokenProvider();
    if (token == null || token.isEmpty) {
      throw const CloudIndexException(
          'Sign in to your Apex AI account before using Cloud Sync.',
          statusCode: 401);
    }
    final uri = Uri.parse('$baseUrl$path');
    final headers = <String, String>{
      'authorization': 'Bearer $token',
      'content-type': 'application/json',
      'accept': 'application/json',
    };
    late http.Response response;
    switch (method) {
      case 'GET':
        response = await client.get(uri, headers: headers);
      case 'POST':
        response =
            await client.post(uri, headers: headers, body: jsonEncode(body));
      case 'DELETE':
        response = await client.delete(uri,
            headers: headers, body: body == null ? null : jsonEncode(body));
      default:
        throw ArgumentError.value(method, 'method');
    }
    Map<String, dynamic> decoded = <String, dynamic>{};
    if (response.body.isNotEmpty) {
      try {
        decoded = (jsonDecode(response.body) as Map).cast<String, dynamic>();
      } catch (_) {}
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CloudIndexException(
        '${decoded['error'] ?? 'Cloud request failed.'}',
        statusCode: response.statusCode,
      );
    }
    return decoded;
  }

  Future<List<CloudSearchHit>> search(List<num> embedding,
      {int limit = 12}) async {
    final json = await _request('POST', '/v1/search', body: {
      'embedding': embedding,
      'limit': limit.clamp(1, 25),
    });
    return (json['results'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => CloudSearchHit.fromJson(row.cast<String, dynamic>()))
        .toList();
  }

  Future<Map<String, dynamic>> status() => _request('GET', '/v1/index/status');

  Future<void> syncBatch({
    required String deviceId,
    required List<Map<String, Object?>> documents,
  }) async {
    await _request('POST', '/v1/index/sync', body: {
      'deviceId': deviceId,
      'documents': documents,
    });
  }

  Future<void> deleteDocument(String documentId) => _request(
        'POST',
        '/v1/index/delete-document',
        body: {'documentId': documentId},
      );

  Future<void> deleteIndex() => _request('DELETE', '/v1/index');
}
