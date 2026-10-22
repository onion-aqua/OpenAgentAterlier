/// A local editing copy. Committing it is explicit so Cancel never changes
/// active prompts or any of the other slots.
enum SettingsSlotKind { user, character, world }

class SettingsSlots {
  static const count = 5;
  SettingsSlots({this.active = 0, List<Map<String, String>?>? entries})
    : entries = List.generate(count, (i) {
        final entry = entries != null && i < entries.length ? entries[i] : null;
        return entry == null ? null : Map<String, String>.of(entry);
      });

  int active;
  final List<Map<String, String>?> entries;

  SettingsSlots copy() => SettingsSlots(active: active, entries: entries);

  factory SettingsSlots.fromJson(Object? value) {
    if (value is! Map) return SettingsSlots();
    final raw = value['entries'];
    return SettingsSlots(
      active: value['active'] is int
          ? (value['active'] as int).clamp(0, count - 1)
          : 0,
      entries: raw is List
          ? raw
                .take(count)
                .map(
                  (entry) => entry is Map
                      ? <String, String>{
                          for (final item in entry.entries)
                            if (item.key is String && item.value is String)
                              item.key as String: item.value as String,
                        }
                      : null,
                )
                .toList()
          : null,
    );
  }

  Map<String, dynamic> toJson() => {'active': active, 'entries': entries};
}
