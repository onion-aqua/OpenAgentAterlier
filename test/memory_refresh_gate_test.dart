import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/memory_refresh_gate.dart';

void main() {
  test('stale completion cannot release a newer refresh after invalidation', () {
    final gate = MemoryRefreshGate();
    final first = gate.begin();
    expect(first, isNotNull);
    expect(gate.running, isTrue);

    // A save switch, manual edit, or failed/aborted model request invalidates
    // the in-flight generation before a replacement refresh starts.
    gate.invalidate(afterLoad: true);
    expect(gate.running, isFalse);
    expect(gate.refreshAfterLoad, isTrue);

    final replacement = gate.begin();
    expect(replacement, isNotNull);
    expect(replacement, isNot(first));
    expect(gate.running, isTrue);

    // The old model future may still complete; it must not unlock replacement.
    expect(gate.finish(first!), isFalse);
    expect(gate.running, isTrue);
    expect(gate.owns(replacement!), isTrue);

    expect(gate.finish(replacement), isTrue);
    expect(gate.running, isFalse);
  });

  test('a failed refresh can be finished without leaving the gate locked', () {
    final gate = MemoryRefreshGate();
    final token = gate.begin();
    expect(token, isNotNull);

    // The caller invokes finish in its finally block after transport errors.
    expect(gate.finish(token!), isTrue);
    expect(gate.running, isFalse);
    expect(gate.begin(), isNotNull);
  });

  test(
    'failed memory batch is cooled down, while another batch can proceed',
    () {
      final cooldown = MemoryBatchRetryCooldown();
      final now = DateTime(2026, 10, 11, 12);
      cooldown.markFailed(
        'save-2:0:8:4',
        retryAfter: now.add(const Duration(minutes: 2)),
      );

      expect(cooldown.isCooling('save-2:0:8:4', now: now), isTrue);
      expect(cooldown.isCooling('save-2:8:16:4', now: now), isFalse);
      expect(
        cooldown.isCooling(
          'save-2:0:8:4',
          now: now.add(const Duration(minutes: 2)),
        ),
        isFalse,
      );
    },
  );

  test('successful or manual retry can clear the automatic batch cooldown', () {
    final cooldown = MemoryBatchRetryCooldown();
    final now = DateTime(2026, 10, 11, 12);
    cooldown.markFailed(
      'save-2:0:8:4',
      retryAfter: now.add(const Duration(minutes: 2)),
    );

    // The cooldown only gates callers that choose to consult it.  Manual
    // consolidation can run directly and clear the automatic retry state.
    cooldown.markSucceeded();
    expect(cooldown.isCooling('save-2:0:8:4', now: now), isFalse);

    cooldown.markFailed(
      'save-2:0:8:4',
      retryAfter: now.add(const Duration(minutes: 2)),
    );
    cooldown.clear();
    expect(cooldown.isCooling('save-2:0:8:4', now: now), isFalse);
  });

  test(
    'retry identity changes when the contents of a same-size batch change',
    () async {
      Future<String> key(List<String> memories) => buildMemoryBatchRetryKey(
        dataRevision: 2,
        start: 0,
        end: 8,
        memoryEditRevision: 4,
        memories: memories,
      );

      final original = List<String>.generate(8, (index) => 'memory $index');
      final replacement = [...original]..[7] = 'withdrawn memory replacement';

      expect(await key(original), isNot(await key(replacement)));
      expect(await key(original), await key([...original]));
    },
  );
}
