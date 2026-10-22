import 'dart:convert';

import 'memory_text.dart';
import 'memory_timeline.dart';

/// A small, deterministic memory layer inspired by Horae's append-only
/// timeline. It deliberately records only high-signal statements. The LLM may
/// enrich the timeline later, but it cannot be the only source of truth.
class MemoryLedgerFact {
  const MemoryLedgerFact({
    required this.category,
    required this.summary,
    required this.keywords,
    required this.importance,
    required this.sourceMessageId,
    required this.observedAt,
    this.sourceRole = 'conversation',
    this.confidence = 0.95,
  });

  final String category;
  final String summary;
  final List<String> keywords;
  final int importance;
  final String sourceMessageId;
  final DateTime observedAt;
  final String sourceRole;
  final double confidence;

  Map<String, dynamic> toJson() => {
    'date': _dateOnly(observedAt),
    'category': category,
    'importance': importance,
    'summary': summary,
    'keywords': keywords,
    'source': 'local_ledger',
    'local_ledger_version': 2,
    'source_role': sourceRole,
    'source_message_id': sourceMessageId,
    'observed_at': observedAt.toIso8601String(),
    'confidence': confidence,
  };

  static String _dateOnly(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

class MemoryLedger {
  MemoryLedger._();

  static final _sentences = RegExp(r'[^。！？!?；;\n]+[。！？!?；;]?');
  static final _speakerPrefix = RegExp(
    r'^\s*(主角|protagonist|莱莎|莱沙|ライザ|苏菲|蘇菲|ソフィー|ryza|sophie|角色\s*\[\s*[^\]\r\n]+\s*\])\s*[：:]\s*',
    caseSensitive: false,
  );
  static final _narratorPrefix = RegExp(
    r'^\s*(?:旁白|narrator)\s*[：:]',
    caseSensitive: false,
  );
  static final _latinToken = RegExp(
    r'[a-z0-9][a-z0-9_\-]{1,}',
    caseSensitive: false,
  );
  static final _cjkRun = RegExp(r'[\u3400-\u9fff\uf900-\ufaff]+');
  static final _commonWords = <String>{
    '然后',
    '但是',
    '已经',
    '现在',
    '今天',
    '我们',
    '你们',
    '自己',
    '这个',
    '那个',
    '什么',
    '怎么',
    '可以',
    '一下',
    'いる',
    'する',
    'こと',
  };

  /// Extracts only statements with an explicit durable signal. This is a
  /// conservative fallback, so a false negative is safer than inventing a
  /// relationship, item, or promise.
  static List<MemoryLedgerFact> extractTurn({
    required String userText,
    required String assistantText,
    required String sourceMessageId,
    DateTime? now,
  }) {
    final observedAt = now ?? DateTime.now();
    if (sourceMessageId.trim().isEmpty) return const [];
    final sentences = <({String text, String role, String actor})>[];
    for (final (text, role) in <(String, String)>[
      (userText, 'user'),
      (assistantText, 'assistant'),
    ]) {
      final source = _clean(text);
      if (source.isEmpty) continue;
      for (final line in source.split('\n')) {
        // A colon is ordinary content unless an assistant line explicitly
        // names a supported speaker. User assertions must retain their prefix.
        final prefix = role == 'assistant'
            ? _speakerPrefix.firstMatch(line)
            : null;
        final actor = role == 'user'
            ? '用户'
            : _narratorPrefix.hasMatch(line)
            ? ''
            : prefix?.group(1)?.trim() ?? '角色';
        final body = prefix == null ? line : line.substring(prefix.end);
        for (final match in _sentences.allMatches(body)) {
          final raw = match.group(0)!.trim();
          if (RegExp(r'[?？]$').hasMatch(raw)) continue;
          final sentence = _clean(raw.replaceFirst(RegExp(r'[。！!；;]$'), ''));
          if (sentence.length >= 4) {
            sentences.add((text: sentence, role: role, actor: actor));
          }
        }
      }
    }
    if (sentences.isEmpty) return const [];

    final facts = <MemoryLedgerFact>[];
    final seen = <String, int>{};
    void add(
      String category,
      RegExp signal, {
      int importance = 3,
      String? onlyRole,
    }) {
      for (final sentence in sentences) {
        if (onlyRole != null && sentence.role != onlyRole) continue;
        if (!signal.hasMatch(sentence.text)) continue;
        // A question or an unaccepted request is not a completed event.
        if (RegExp(
          r'(?:吗|呢)$|能否|能不能|可以不可以|要不要|もし|でしょうか|ですか|ませんか|would you|could you|can you',
          caseSensitive: false,
        ).hasMatch(sentence.text)) {
          continue;
        }
        if (category != 'user_preference' &&
            RegExp(
              r'如果|假如|要是|希望|想要|打算|计划|^(?:请|帮我|给我)|\b(?:if|wish|want to|please)\b',
              caseSensitive: false,
            ).hasMatch(sentence.text)) {
          continue;
        }
        final keywords = _keywords(sentence.text)
            .take(8)
            .toList(growable: false);
        if (keywords.isEmpty) continue;
        final summary = _factSummary(
          sentence.text,
          actor: sentence.actor,
          category: category,
        );
        // Preserve a complete assertion. A half sentence changes its meaning;
        // oversized dialogue is left for the model-backed recent summary.
        if (summary.runes.length > 400) continue;
        final key = '${sentence.role}|${_comparable(sentence.text)}';
        final existingIndex = seen[key];
        if (existingIndex != null &&
            facts[existingIndex].importance >= importance) {
          continue;
        }
        final fact = MemoryLedgerFact(
          category: category,
          summary: summary,
          keywords: keywords,
          importance: importance,
          sourceMessageId: sourceMessageId,
          sourceRole: sentence.role,
          observedAt: observedAt,
        );
        if (existingIndex == null) {
          seen[key] = facts.length;
          facts.add(fact);
        } else {
          facts[existingIndex] = fact;
        }
      }
    }

    add(
      'promise',
      RegExp(
        r'约定|答应|承诺|约好|之后一起|一定会|明天.{0,16}(?:一起|出发)|下次.{0,16}一起|\bpromise\b|\bagreed?\b|tomorrow.{0,24}together|約束|明日.{0,16}(?:一緒|出発)',
        caseSensitive: false,
      ),
      importance: 5,
    );
    add(
      'item',
      RegExp(
        r'送给|给你|收到|获得|拿到|找到|买到|丢失|扔掉|消耗|用掉|带来|gift|received|found|lost|used up|プレゼント|見つけ',
        caseSensitive: false,
      ),
    );
    add(
      'scene',
      RegExp(
        r'到达|去了|前往|来到|回到|离开|抵达|arrive|went to|leave|到着|向かう',
        caseSensitive: false,
      ),
    );
    add(
      'relationship_turning_point',
      RegExp(
        r'成为朋友|确认.{0,8}关系|喜欢你|爱你|和好|原谅|告白|背叛|分手|结婚|朋友了|love you|confess|betray|break up|marry|友達にな|(?:あなた|君|お前).{0,8}(?:が|のことが)好き|仲直り|告白',
        caseSensitive: false,
      ),
      importance: 5,
    );
    add(
      'user_preference',
      RegExp(
        r'我喜欢|我讨厌|我希望|请不要|不要叫我|叫我|我的名字是|i like|i hate|please don.t|call me|私の名前は|(?:私|わたし|僕|ぼく|俺).{0,16}(?:が好き|大好き|が嫌い)',
        caseSensitive: false,
      ),
      importance: 4,
      onlyRole: 'user',
    );
    // Delivery tags and transient emotions belong to the recent context.
    // The model may retain an emotional event when its lasting cause/result
    // is explicit; a keyword alone cannot establish a long-term event.
    return facts;
  }

  /// Merge local facts as append-only candidates. Existing entries always win
  /// on duplicate sequence/id, and the timeline's deletion and similarity
  /// guards remain in charge of deduplication.
  static String? mergeIntoTimeline(
    String previousMemory,
    Iterable<MemoryLedgerFact> facts, {
    DateTime? now,
  }) {
    final pending = facts.toList(growable: false);
    if (pending.isEmpty) {
      return MemoryTimeline.normalizeExisting(previousMemory);
    }
    return MemoryTimeline.normalizeCandidate(
      jsonEncode({
        'entries': [for (final fact in pending) fact.toJson()],
      }),
      previousMemory: previousMemory,
      now: now,
    );
  }

  static String _clean(String value) {
    return cleanMemoryText(value, preserveLines: true)
        .split('\n')
        .where(
          (line) => !RegExp(
            r'^\s*(?:译文|翻译|translation|日本語訳)\s*[:：]',
            caseSensitive: false,
          ).hasMatch(line),
        )
        .join('\n')
        .trim();
  }

  static String _factSummary(
    String text, {
    required String actor,
    required String category,
  }) {
    var assertion = text.replaceFirst(RegExp(r'^(?:好(?:的)?|嗯|是的)[，,、]\s*'), '');
    if (actor.isNotEmpty && assertion.startsWith('我们')) {
      assertion = '用户与角色${assertion.substring(2)}';
    } else if (actor.isNotEmpty && assertion.startsWith('我')) {
      assertion = '$actor${assertion.substring(1)}';
    }
    final label = switch (category) {
      'promise' => '确认约定',
      'item' => '确认物品变化',
      'scene' => '确认地点变化',
      'relationship_turning_point' => '确认关系变化',
      'user_preference' => '表达偏好',
      _ => '确认事实',
    };
    return '$actor$label：$assertion。';
  }

  static Iterable<String> _keywords(String value) sync* {
    final lower = value.toLowerCase();
    for (final match in _latinToken.allMatches(lower)) {
      final token = match.group(0)!;
      if (token.length >= 2 && !_commonWords.contains(token)) yield token;
    }
    for (final match in _cjkRun.allMatches(value)) {
      final run = match.group(0)!;
      final chars = run.runes.toList();
      for (var i = 0; i < chars.length; i++) {
        final one = String.fromCharCode(chars[i]);
        if (!_commonWords.contains(one)) yield one;
        if (i + 1 < chars.length) {
          final pair = String.fromCharCodes([chars[i], chars[i + 1]]);
          if (!_commonWords.contains(pair)) yield pair;
        }
      }
    }
  }

  static String _comparable(String value) => value.toLowerCase().replaceAll(
    RegExp(r'[\s\p{P}\p{S}]', unicode: true),
    '',
  );
}
