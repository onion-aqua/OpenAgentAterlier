import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// A load invalidates old requests without letting their completion release
/// the lock or pending work owned by a newer request.
class MemoryRefreshGate {
  int _generation = 0;
  bool running = false;
  bool refreshAfterLoad = false;
  int? begin() {
    if (running) return null;
    running = true;
    return ++_generation;
  }

  bool owns(int token) => token == _generation;
  bool finish(int token) {
    if (!owns(token)) return false;
    running = false;
    return true;
  }

  void invalidate({bool afterLoad = false}) {
    _generation++;
    running = false;
    refreshAfterLoad = afterLoad;
  }
}

/// Suppresses automatic retries of one failed long-term-memory batch.
///
/// Kept outside the widget so timeout/backoff behavior can be tested without
/// mounting the full chat screen.  It is intentionally not persisted: manual
/// consolidation and a fresh app session remain available to the user.
class MemoryBatchRetryCooldown {
  String? _failedKey;
  DateTime? _retryAfter;

  bool isCooling(String key, {DateTime? now}) {
    if (_failedKey != key || _retryAfter == null) return false;
    if ((now ?? DateTime.now()).isBefore(_retryAfter!)) return true;
    clear();
    return false;
  }

  void markFailed(String key, {required DateTime retryAfter}) {
    _failedKey = key;
    _retryAfter = retryAfter;
  }

  void markSucceeded() => clear();

  void clear() {
    _failedKey = null;
    _retryAfter = null;
  }
}

/// Builds a cooldown identity for one exact batch, including its contents.
///
/// Recent memories can be withdrawn or edited while the batch count and save
/// revisions remain unchanged.  Hashing the ordered batch prevents a failed
/// request for the old content from suppressing a different replacement batch.
Future<String> buildMemoryBatchRetryKey({
  required int dataRevision,
  required int start,
  required int end,
  required int memoryEditRevision,
  required List<String> memories,
}) async {
  final digest = await Sha256().hash(utf8.encode(jsonEncode(memories)));
  final fingerprint = base64UrlEncode(digest.bytes).replaceAll('=', '');
  return '$dataRevision:$start:$end:$memoryEditRevision:$fingerprint';
}
