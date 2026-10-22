import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/model_mapping_service.dart';
import 'package:ryza_chat_mvp/src/model_resource_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingClient extends http.BaseClient {
  _RecordingClient(Future<http.Response> Function(http.Request) handler)
    : _inner = MockClient(handler);

  final MockClient _inner;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {
    closed = true;
    _inner.close();
  }
}

class _StalledClient extends http.BaseClient {
  final Completer<http.StreamedResponse> _pending = Completer();
  int requests = 0;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests++;
    return _pending.future;
  }

  @override
  void close() {
    if (closed) return;
    closed = true;
    if (!_pending.isCompleted) {
      _pending.completeError(http.ClientException('closed'));
    }
  }
}

ModelResourceCatalog _catalog() => ModelResourceCatalog(
  format: ModelResourceFormat.spine,
  sourceFingerprint: 'fingerprint',
  runtimeVersion: '4.2.43',
  entryFile: 'model.skel',
  resources: const [
    ModelResource(
      id: 'animation:wait',
      kind: ModelResourceKinds.animation,
      name: 'wait',
      native: {'name': 'wait'},
    ),
  ],
  runtimeSupported: false,
  compatibilityIssues: const ['test-only runtime issue'],
);

String _validMapping() => jsonEncode({
  'schemaVersion': 1,
  'sourceFingerprint': 'fingerprint',
  'format': 'spine',
  'label': 'Test rig',
  'idle': 'animation:wait',
  'actions': {},
  'expressions': {},
  'parameters': {},
  'notes': ['No semantic actions were inferred.'],
});

http.Response _openAiResponse() => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {'content': _validMapping()},
      },
    ],
  }),
  200,
);

http.Response _geminiResponse() => http.Response(
  jsonEncode({
    'status': 'completed',
    'steps': [
      {
        'type': 'model_output',
        'content': [
          {'type': 'text', 'text': _validMapping()},
        ],
      },
    ],
  }),
  200,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('sends only the system contract and catalog snapshot once', () async {
    final controller = await AppController.load();
    var calls = 0;
    late String system;
    late String input;
    final service = ModelMappingService(
      transport: (capturedSystem, capturedInput) async {
        calls++;
        system = capturedSystem;
        input = capturedInput;
        return _validMapping();
      },
    );

    final result = await service.analyze(_catalog(), controller: controller);
    final payload = jsonDecode(input) as Map;

    expect(calls, 1);
    expect(result.idle, 'animation:wait');
    expect(system, contains('不确定'));
    expect(system, contains('不要输出或改写 runtimeSupported'));
    expect(system, contains('严格结构示例'));
    expect(system, contains('Spine 的 idle 必须'));
    expect(system, contains('acknowledge、disagree、think'));
    expect(system, contains('普通的一段说话'));
    expect(system, contains('0..1'));
    expect(payload['sourceFingerprint'], 'fingerprint');
    expect(payload['resources'], hasLength(1));
    expect(payload, isNot(contains('messages')));
    expect(payload, isNot(contains('memory')));
    expect(payload, isNot(contains('apiKey')));
  });

  test('does not retry invalid model output', () async {
    final controller = await AppController.load();
    var calls = 0;
    final service = ModelMappingService(
      transport: (_, _) async {
        calls++;
        return 'not json';
      },
    );

    await expectLater(
      service.analyze(_catalog(), controller: controller),
      throwsFormatException,
    );
    expect(calls, 1);
  });

  test('the 90 second budget also wraps an injected transport', () async {
    final controller = await AppController.load();
    final pending = Completer<String>();
    var calls = 0;
    final service = ModelMappingService(
      analysisTimeout: const Duration(milliseconds: 20),
      transport: (_, _) {
        calls++;
        return pending.future;
      },
    );

    await expectLater(
      service.analyze(_catalog(), controller: controller),
      throwsA(isA<TimeoutException>()),
    );
    expect(calls, 1);
  });

  test(
    'OpenAI request uses the active profile and exactly two messages',
    () async {
      const secret = 'openai-mapping-secret';
      FlutterSecureStorage.setMockInitialValues({'openai_api_key': secret});
      final controller = await AppController.load();
      controller.configureAi(
        enabled: true,
        baseUrl: 'https://llm.example.test/v1/',
        model: 'mapping-model',
      );
      late http.Request captured;
      final client = _RecordingClient((request) async {
        captured = request;
        return _openAiResponse();
      });

      final mapping = await ModelMappingService(client: client)
          .analyze(_catalog(), controller: controller);
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      final messages = body['messages'] as List;

      expect(mapping.idle, 'animation:wait');
      expect(
        captured.url.toString(),
        'https://llm.example.test/v1/chat/completions',
      );
      expect(captured.headers['authorization'], 'Bearer $secret');
      expect(body['model'], 'mapping-model');
      expect(body['stream'], isFalse);
      expect(messages, hasLength(2));
      expect((messages.first as Map)['role'], 'system');
      expect((messages.last as Map)['role'], 'user');
      expect(body, isNot(contains('tools')));
      expect(captured.body, isNot(contains(secret)));
      expect(client.closed, isTrue);
    },
  );

  test(
    'Gemini request uses the existing stateless interactions schema',
    () async {
      const secret = 'gemini-mapping-secret';
      FlutterSecureStorage.setMockInitialValues({'gemini_api_key': secret});
      final controller = await AppController.load();
      controller.configureGemini(
        enabled: true,
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
        model: 'gemini-mapping',
      );
      late http.Request captured;
      final client = _RecordingClient((request) async {
        captured = request;
        return _geminiResponse();
      });

      await ModelMappingService(client: client)
          .analyze(_catalog(), controller: controller);
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      final input = body['input'] as List;
      final userInput = input.single as Map;

      expect(
        captured.url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/interactions',
      );
      expect(captured.headers['x-goog-api-key'], secret);
      expect(body['model'], 'gemini-mapping');
      expect(body['system_instruction'], ModelMappingService.systemPrompt);
      expect(body['store'], isFalse);
      expect(body['stream'], isFalse);
      expect(userInput['type'], 'user_input');
      expect(userInput['content'], hasLength(1));
      expect(body, isNot(contains('tools')));
      expect(captured.body, isNot(contains(secret)));
      expect(client.closed, isTrue);
    },
  );

  test(
    'HTTP errors are single-shot and do not expose credentials or body',
    () async {
      const secret = 'private-mapping-key';
      const bodyMarker = 'private-provider-debug-body';
      FlutterSecureStorage.setMockInitialValues({'openai_api_key': secret});
      final controller = await AppController.load();
      controller.configureAi(
        enabled: true,
        baseUrl: 'https://llm.example.test/v1',
        model: 'mapping-model',
      );
      var requests = 0;
      final client = _RecordingClient((_) async {
        requests++;
        return http.Response(bodyMarker, 503);
      });

      await expectLater(
        ModelMappingService(client: client)
            .analyze(_catalog(), controller: controller),
        throwsA(
          isA<StateError>()
              .having((error) => '$error', 'status', contains('503'))
              .having((error) => '$error', 'secret', isNot(contains(secret)))
              .having(
                (error) => '$error',
                'response body',
                isNot(contains(bodyMarker)),
              ),
        ),
      );
      expect(requests, 1);
      expect(client.closed, isTrue);
    },
  );

  test('HTTP timeout closes the client and makes only one request', () async {
    FlutterSecureStorage.setMockInitialValues({
      'openai_api_key': 'timeout-key',
    });
    final controller = await AppController.load();
    controller.configureAi(
      enabled: true,
      baseUrl: 'https://llm.example.test/v1',
      model: 'mapping-model',
    );
    final client = _StalledClient();

    await expectLater(
      ModelMappingService(
        client: client,
        analysisTimeout: const Duration(milliseconds: 20),
      ).analyze(_catalog(), controller: controller),
      throwsA(isA<TimeoutException>()),
    );
    expect(client.requests, 1);
    expect(client.closed, isTrue);
  });

  test('rejects a model attempt to forge runtime support', () async {
    final controller = await AppController.load();
    final service = ModelMappingService(
      transport: (_, _) async => jsonEncode({
        'schemaVersion': 1,
        'sourceFingerprint': 'fingerprint',
        'format': 'spine',
        'label': 'Test rig',
        'idle': null,
        'actions': {},
        'expressions': {},
        'parameters': {},
        'notes': [],
        'runtimeSupported': true,
      }),
    );

    await expectLater(
      service.analyze(_catalog(), controller: controller),
      throwsFormatException,
    );
  });
}
