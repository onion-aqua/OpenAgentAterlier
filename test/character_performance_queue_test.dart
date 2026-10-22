import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_performance_queue.dart';
import 'package:ryza_chat_mvp/src/character_performance.dart';
import 'package:ryza_chat_mvp/src/character_expression.dart';

void main() {
  test('paired intentions retain order, deduplicate and expire', () {
    final q = CharacterPerformanceQueue();
    final now = DateTime(2026);
    q.add(CharacterAction.invite, CharacterExpression.cuddle, now);
    q.add(CharacterAction.invite, CharacterExpression.cuddle, now);
    q.add(CharacterAction.shy, CharacterExpression.cuddle, now);
    expect(q.take(now)!.action, CharacterAction.invite);
    final next = q.take(now)!;
    expect(next.action, CharacterAction.shy);
    expect(next.expression, CharacterExpression.cuddle);
    expect(q.take(now), isNull);
    q.add(CharacterAction.wave, CharacterExpression.happy, now);
    expect(q.take(now.add(const Duration(seconds: 6))), isNull);
    q.add(CharacterAction.think, CharacterExpression.neutral, now);
    q.clear();
    expect(q.take(now), isNull);
  });
}
