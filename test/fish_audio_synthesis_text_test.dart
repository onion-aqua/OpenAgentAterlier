import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'REST sends cleaned speech while keeping model, voice and speed',
    () async {
      var requests = 0;
      final transport = MockClient((request) async {
        requests++;
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        expect(payload['text'], '[sad][whispering]大丈夫。待って、ここにいるよ。');
        expect(payload['reference_id'], 'test-voice');
        expect(request.headers['model'], 'drama-3');
        expect((payload['prosody'] as Map)['speed'], .75);
        return http.Response.bytes([0x49, 0x44, 0x33], 200);
      });
      addTearDown(transport.close);
      await FishAudioClient(client: transport).synthesizeBytes(
        apiKey: 'test-only-key',
        referenceId: 'test-voice',
        model: 'drama-3',
        speed: .75,
        text: '[sad][breathy][whispering]大丈夫。[gasping]待って、ここにいるよ。[long pause]',
      );
      expect(requests, 1);
    },
  );

  test(
    'empty or breathing-only payload never reaches the REST transport',
    () async {
      var requests = 0;
      final transport = MockClient((_) async {
        requests++;
        return http.Response.bytes([0x49, 0x44, 0x33], 200);
      });
      addTearDown(transport.close);
      final client = FishAudioClient(client: transport);
      for (final text in [
        '',
        '  ',
        '[breathy][panting][inhale]',
        '[whispering][sighing]',
      ]) {
        await expectLater(
          client.synthesizeBytes(
            apiKey: 'test-only-key',
            referenceId: 'test-voice',
            text: text,
          ),
          throwsA(isA<AiServiceException>()),
        );
      }
      expect(requests, 0);
    },
  );
}
