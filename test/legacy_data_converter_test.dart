import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/legacy_data_converter.dart';

void main() {
  test('sanitizes API keys and binary payloads', () {
    final value = sanitizeLegacyData({
      'apiKey': 'secret',
      'attachments': [
        {'thumbnailBase64': 'binary', 'name': 'photo.png'},
      ],
      'text': 'hello',
    });
    expect(value, {
      'attachments': [
        {'name': 'photo.png'},
      ],
      'text': 'hello',
    });
  });

  test('parses fenced model output and normalizes messages', () {
    final result = parseLegacyMigrationResponse('''```json
{"messages":[{"role":"user","content":"hello"}],"relationshipPoints":2.6}
```''');
    expect(result['format'], 'agent-atelier-r-local-backup');
    expect(result['version'], 1);
    expect(result['relationshipPoints'], 3);
    expect(result['messages'], [
      {'text': 'hello', 'isUser': true, 'attachments': []},
    ]);
  });

  test('merges converted fields without dropping current settings', () {
    final merged = mergeLegacyMigration(
      {
        'format': 'agent-atelier-r-local-backup',
        'version': 1,
        'preferences': {'themePreference': 'dark', 'aiEnabled': true},
      },
      {
        'messages': [
          {'text': 'hi', 'isUser': false},
        ],
        'preferences': {'aiEnabled': false},
      },
    );
    expect(merged['preferences'], {
      'themePreference': 'dark',
      'aiEnabled': false,
    });
    expect(merged['messages'], isA<List>());
    expect(merged['format'], 'agent-atelier-r-local-backup');
  });
}
