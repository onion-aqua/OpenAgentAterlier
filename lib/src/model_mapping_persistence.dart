import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

const importedPerformanceMappingFileName = 'performance.mapping.json';
const maxPerformanceMappingBytes = 128 * 1024;

Map<String, Object?> decodeJsonObject(Uint8List bytes, String label) {
  if (bytes.isEmpty || bytes.length > maxPerformanceMappingBytes) {
    throw FormatException('$label exceeds its size limit');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on Object {
    throw FormatException('Invalid $label JSON');
  }
  if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
    throw FormatException('$label must be a JSON object');
  }
  return Map<String, Object?>.from(decoded);
}

Future<Map<String, Object?>> validatePerformanceMapping({
  required Uint8List bytes,
  required Uint8List sourceArchive,
  required String expectedFormat,
}) async {
  final mapping = decodeJsonObject(bytes, 'performance mapping');
  final schemaVersion = mapping['schemaVersion'];
  final fingerprint = mapping['sourceFingerprint'];
  final format = mapping['format'];
  final label = mapping['label'];
  if (schemaVersion is! int ||
      schemaVersion < 1 ||
      fingerprint is! String ||
      fingerprint.trim().isEmpty ||
      format is! String ||
      format != expectedFormat ||
      label is! String ||
      label.trim().isEmpty ||
      (mapping['idle'] != null && mapping['idle'] is! String) ||
      mapping['actions'] is! Map ||
      mapping['expressions'] is! Map ||
      mapping['parameters'] is! Map ||
      mapping['notes'] is! List ||
      (mapping['notes'] as List).any((note) => note is! String)) {
    throw const FormatException('Invalid performance mapping');
  }
  final digest = _hex((await Sha256().hash(sourceArchive)).bytes);
  if (fingerprint.trim().toLowerCase() != digest) {
    throw const FormatException(
      'Performance mapping does not match the selected model package',
    );
  }
  return mapping;
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
