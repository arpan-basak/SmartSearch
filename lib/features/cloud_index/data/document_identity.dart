import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Produces a stable opaque identifier without exposing an Android content URI.
String cloudDocumentId({
  required String deviceId,
  required String fileHash,
  required int fileSize,
  required int modifiedSeconds,
}) {
  if (deviceId.isEmpty || fileHash.isEmpty) {
    throw ArgumentError('A device ID and file hash are required.');
  }
  final identity =
      '$deviceId\u0000$fileHash\u0000$fileSize\u0000$modifiedSeconds';
  return sha256.convert(utf8.encode(identity)).toString();
}

String cloudRevision({
  required String fileHash,
  required int fileSize,
  required int modifiedSeconds,
}) =>
    sha256
        .convert(utf8.encode('$fileHash\u0000$fileSize\u0000$modifiedSeconds'))
        .toString();

String cloudGraphId(Iterable<Object?> parts) => sha256
    .convert(utf8.encode(parts.map((part) => '$part').join('\u0000')))
    .toString();
