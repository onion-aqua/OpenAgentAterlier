/// Names are presentation data; this resolver always returns a catalog ID.
/// It carries no character prompts, private messages or service configuration.
class CharacterIdentityRecord {
  CharacterIdentityRecord({required this.id, required Iterable<String> aliases})
    : aliases = Set<String>.unmodifiable({
        normalizeCharacterIdentityName(id),
        ...aliases
            .map(normalizeCharacterIdentityName)
            .where((s) => s.isNotEmpty),
      });

  final String id;
  final Set<String> aliases;
}

/// Normalize typography rather than spelling: full-width Latin text and common
/// name separators should not create a second identity or change a save key.
String normalizeCharacterIdentityName(String value) {
  final widthNormalized = String.fromCharCodes(
    value.runes.map((rune) {
      if (rune >= 0xff01 && rune <= 0xff5e) return rune - 0xfee0;
      return rune == 0x3000 ? 0x20 : rune;
    }),
  );
  return widthNormalized
      .replaceAll(RegExp('[・•∙]'), '·')
      .replaceAll(RegExp('[’‘]'), "'")
      .replaceAll(RegExp(r'\s*·\s*'), '·')
      .replaceAll(RegExp(r'\s*\(\s*'), '(')
      .replaceAll(RegExp(r'\s*\)'), ')')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toLowerCase();
}

class CharacterIdentityResolver {
  CharacterIdentityResolver(
    Iterable<CharacterIdentityRecord> identities, {
    Iterable<String> blockedNames = const [],
  }) {
    final aliases = <String, Set<String>>{};
    for (final identity in identities) {
      for (final alias in identity.aliases) {
        aliases.putIfAbsent(alias, () => <String>{}).add(identity.id);
      }
    }
    _exact = Map<String, Set<String>>.unmodifiable({
      for (final entry in aliases.entries)
        entry.key: Set<String>.unmodifiable(entry.value),
    });
    _patterns = [
      for (final entry in _exact.entries)
        _IdentityPattern(entry.key, entry.value),
      for (final name in blockedNames.map(normalizeCharacterIdentityName))
        if (name.isNotEmpty && !_exact.containsKey(name))
          _IdentityPattern(name, const {}),
    ];
  }

  late final Map<String, Set<String>> _exact;
  late final List<_IdentityPattern> _patterns;
  String? _lastInput;
  Set<String> _lastMentions = const {};

  /// An ambiguous shared alias never selects whichever entry came first.
  String? resolve(String value) {
    final ids = exactIds(value);
    return ids.length == 1 ? ids.single : null;
  }

  Set<String> exactIds(String value) =>
      _exact[normalizeCharacterIdentityName(value)] ?? const {};

  Set<String> partialIds(String value) {
    final query = normalizeCharacterIdentityName(value);
    if (query.length < 2) return const {};
    return Set<String>.unmodifiable({
      for (final entry in _exact.entries)
        if (entry.key.contains(query)) ...entry.value,
    });
  }

  /// Longer catalog names suppress embedded shorter names at that occurrence.
  /// Shared, unqualified names retain all candidate IDs for disambiguation.
  Set<String> mentionedIds(String input) {
    final text = normalizeCharacterIdentityName(input);
    if (_lastInput == text) return _lastMentions;
    final spans = <_IdentityOccurrence>[];
    for (final pattern in _patterns) {
      for (final match in pattern.expression.allMatches(text)) {
        // Latin boundary checks use lookarounds, so match offsets are exactly
        // the alias span and can be compared with a longer qualified name.
        spans.add(_IdentityOccurrence(match.start, match.end, pattern.ids));
      }
    }
    final result = <String>{};
    for (final span in spans) {
      final covered = spans.any(
        (other) =>
            other.end - other.start > span.end - span.start &&
            other.start <= span.start &&
            other.end >= span.end,
      );
      if (!covered) result.addAll(span.ids);
    }
    _lastInput = text;
    return _lastMentions = Set<String>.unmodifiable(result);
  }
}

class _IdentityPattern {
  _IdentityPattern(String alias, this.ids)
    : expression = RegExp(
        RegExp(r"^[a-z0-9 _.:'()-]+$").hasMatch(alias)
            ? '(?<![a-z0-9_])${RegExp.escape(alias)}(?![a-z0-9_])'
            : RegExp.escape(alias),
      );

  final RegExp expression;
  final Set<String> ids;
}

class _IdentityOccurrence {
  const _IdentityOccurrence(this.start, this.end, this.ids);

  final int start;
  final int end;
  final Set<String> ids;
}
