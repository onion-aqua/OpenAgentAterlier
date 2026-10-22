/// Public configuration only. API keys belong exclusively in SecretStore.
class OpenAiConfigurationSlots {
  static const count = 3;

  OpenAiConfigurationSlots({
    this.active = 0,
    List<Map<String, String>?>? entries,
  }) : entries = List.generate(count, (index) {
         final entry = entries != null && index < entries.length
             ? entries[index]
             : null;
         return entry == null
             ? null
             : {
                 'baseUrl': entry['baseUrl'] ?? '',
                 'model': entry['model'] ?? '',
               };
       });

  int active;
  final List<Map<String, String>?> entries;

  OpenAiConfigurationSlots copy() =>
      OpenAiConfigurationSlots(active: active, entries: entries);

  factory OpenAiConfigurationSlots.fromJson(Object? value) {
    if (value is! Map) return OpenAiConfigurationSlots();
    final raw = value['entries'];
    return OpenAiConfigurationSlots(
      active: value['active'] is int
          ? (value['active'] as int).clamp(0, count - 1)
          : 0,
      entries: raw is List
          ? raw
                .take(count)
                .map(
                  (entry) =>
                      entry is Map &&
                          entry['baseUrl'] is String &&
                          entry['model'] is String
                      ? {
                          'baseUrl': entry['baseUrl'] as String,
                          'model': entry['model'] as String,
                        }
                      : null,
                )
                .toList()
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'active': active,
    'entries': copy().entries,
  };

  static void checkIndex(int index) {
    RangeError.checkValueInInterval(index, 0, count - 1, 'slot');
  }
}
