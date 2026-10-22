import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';

http.Response result(List<Map<String, dynamic>> steps) => http.Response(
  jsonEncode({'status': 'completed', 'steps': steps}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
Map<String, dynamic> textStep(String text) => {
  'type': 'model_output',
  'content': [
    {'type': 'text', 'text': text},
  ],
};
String event(Map<String, dynamic> value) => 'data: ${jsonEncode(value)}\n\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'native endpoint migration, auth, local history and memory protocol',
    () async {
      for (final suffix in [
        '/interactions',
        '/openai',
        '',
        '/interactions/chat/completions',
      ]) {
        final client = OpenAiCompatibleClient(
          client: MockClient((request) async {
            expect(request.url.path, '/v1beta/interactions');
            expect(request.headers['x-goog-api-key'], 'test-key');
            expect(request.headers.containsKey('Authorization'), false);
            final body = jsonDecode(request.body) as Map;
            expect(body['store'], false);
            expect(body['system_instruction'], 'system');
            expect(body.containsKey('messages'), false);
            expect(body['input'][0]['type'], 'user_input');
            expect(body['input'][1]['type'], 'model_output');
            return result([textStep('ok')]);
          }),
        );
        expect(
          await client.complete(
            provider: LlmProvider.gemini,
            baseUrl: 'https://generativelanguage.googleapis.com/v1beta$suffix',
            apiKey: 'test-key',
            model: 'user-selected-model',
            messages: [
              {'role': 'system', 'content': 'system'},
              {'role': 'user', 'content': 'hi'},
              {'role': 'assistant', 'content': 'hello'},
            ],
          ),
          'ok',
        );
      }
    },
  );
  test('stream emits text only and rejects truncated streams', () async {
    for (final complete in [true, false]) {
      final client = OpenAiCompatibleClient(
        client: MockClient(
          (request) async => http.Response(
            event({
                  'event_type': 'step.delta',
                  'delta': {'type': 'thought_summary', 'text': 'hidden'},
                }) +
                event({
                  'event_type': 'step.delta',
                  'delta': {'type': 'text', 'text': 'hello'},
                }) +
                (complete
                    ? event({
                        'event_type': 'interaction.completed',
                        'interaction': {'status': 'completed'},
                      })
                    : ''),
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        ),
      );
      final output = client
          .streamChat(
            provider: LlmProvider.gemini,
            baseUrl: 'https://example.test/v1beta',
            apiKey: 'test',
            model: 'test',
            systemPrompt: 'test',
            messages: const [ChatMessage(text: 'hi', isUser: true)],
          )
          .toList();
      if (complete) {
        expect(await output, ['hello']);
      } else {
        await expectLater(output, throwsA(isA<AiServiceException>()));
      }
    }
  });
  test(
    'Gemini accepts DONE variants and final SSE frames without blank lines',
    () async {
      final text = event({
        'event_type': 'step.delta',
        'delta': {'type': 'text', 'text': '你好，莱莎'},
      });
      final completed = event({
        'event_type': 'interaction.completed',
        'interaction': {'status': 'completed'},
      });
      for (final ending in [
        'data: [DONE]\n\n',
        'data: \uFEFF[done]\u0000  \r\n\r\n',
        'data: [DONE]',
        completed.trimRight(),
        '${completed}data: [DONE]\n\n',
      ]) {
        final bytes = utf8.encode(': keepalive\r\n\r\n$text$ending');
        final client = OpenAiCompatibleClient(
          client: MockClient.streaming(
            (request, body) async => http.StreamedResponse(
              Stream.fromIterable([
                // Split every byte, including inside a multi-byte Chinese character.
                for (final byte in bytes) [byte],
              ]),
              200,
              headers: {'content-type': 'text/event-stream'},
            ),
          ),
        );
        expect(
          await client
              .streamChat(
                provider: LlmProvider.gemini,
                baseUrl: 'https://example.test/v1beta',
                apiKey: 'test',
                model: 'test',
                systemPrompt: 'test',
                messages: const [ChatMessage(text: 'hi', isUser: true)],
              )
              .join(),
          '你好，莱莎',
          reason: ending,
        );
      }
    },
  );

  test(
    'DONE never hides a preceding Gemini failure or empty response',
    () async {
      for (final prefix in [
        '',
        event({
          'error': {'message': 'upstream failure'},
        }),
        event({
          'event_type': 'interaction.completed',
          'interaction': {'status': 'failed'},
        }),
      ]) {
        final client = OpenAiCompatibleClient(
          client: MockClient(
            (request) async => http.Response(
              '${prefix}data: [DONE]\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            ),
          ),
        );
        await expectLater(
          client
              .streamChat(
                provider: LlmProvider.gemini,
                baseUrl: 'https://example.test/v1beta',
                apiKey: 'test',
                model: 'test',
                systemPrompt: 'test',
                messages: const [ChatMessage(text: 'hi', isUser: true)],
              )
              .join(),
          throwsA(isA<AiServiceException>()),
        );
      }
    },
  );

  test(
    'agent replays native tool calls and signatures without cloud storage',
    () async {
      var requests = 0;
      var executed = 0;
      final client = OpenAiCompatibleClient(
        contextToolExecutor: (name, args) async => '{"inventory":[]}',
        agentToolExecutor: (name, args) async {
          executed++;
          return '2026-09-09';
        },
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          expect(body['tools'][0]['type'], 'function');
          expect((body['tools'][0] as Map).containsKey('function'), false);
          expect(
            (body['tools'] as List).map((tool) => tool['name']),
            containsAll([
              'inspect_quests',
              'create_quest',
              'inspect_alchemy_inventory',
            ]),
          );
          final gatherTool = (body['tools'] as List).firstWhere(
            (tool) => tool['name'] == 'gather_current_location',
          ) as Map;
          expect(
            (gatherTool['parameters'] as Map)['required'],
            contains('discoveries'),
          );
          if (requests++ == 0) {
            return result([
              {'type': 'thought', 'signature': 'preserved'},
              {
                'type': 'function_call',
                'id': 'call1',
                'name': 'get_local_datetime',
                'arguments': {},
              },
            ]);
          }
          expect(body['input'][1]['signature'], 'preserved');
          expect(body['input'].last['call_id'], 'call1');
          expect(body['input'].last['result'], '2026-09-09');
          return result([textStep('today')]);
        }),
      );
      final output = await client
          .streamChat(
            provider: LlmProvider.gemini,
            baseUrl: 'https://example.test/v1beta',
            apiKey: 'test',
            model: 'test',
            systemPrompt: 'test',
            agentEnabled: true,
            messages: const [ChatMessage(text: 'date', isUser: true)],
          )
          .join();
      expect(output, 'today');
      expect(executed, 1);
      expect(requests, 2);
    },
  );
  test('image and PDF attachments use native content', () async {
    final client = OpenAiCompatibleClient(
      client: MockClient((request) async {
        final parts = jsonDecode(request.body)['input'][0]['content'] as List;
        expect(parts[1], {
          'type': 'image',
          'mime_type': 'image/png',
          'data': 'AQI=',
        });
        expect(parts[2], {
          'type': 'document',
          'mime_type': 'application/pdf',
          'data': 'AQI=',
        });
        return result([textStep('ok')]);
      }),
    );
    await client
        .streamChat(
          provider: LlmProvider.gemini,
          baseUrl: 'https://example.test/v1beta',
          apiKey: 'test',
          model: 'test',
          systemPrompt: 'test',
          messages: [
            ChatMessage(
              text: 'inspect',
              isUser: true,
              attachments: [
                for (final mime in ['image/png', 'application/pdf'])
                  ChatAttachment(
                    name: 'file',
                    mimeType: mime,
                    size: 2,
                    bytes: Uint8List.fromList([1, 2]),
                  ),
              ],
            ),
          ],
        )
        .drain<void>();
  });
  test('HTTP and native failure responses are not silent successes', () async {
    for (final response in [
      http.Response('{"error":{"message":"not found"}}', 404),
      http.Response(
        '{"status":"failed","errors":[{"message":"blocked"}]}',
        200,
      ),
    ]) {
      final client = OpenAiCompatibleClient(
        client: MockClient((_) async => response),
      );
      await expectLater(
        client
            .streamChat(
              provider: LlmProvider.gemini,
              baseUrl: 'https://example.test/v1beta',
              apiKey: 'test',
              model: 'test',
              systemPrompt: 'test',
              messages: const [],
            )
            .toList(),
        throwsA(isA<AiServiceException>()),
      );
    }
  });
}
