import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:ryza_chat_mvp/src/fish_mcp_protocol.dart';

Map<String, dynamic> textSchema({Map<String, dynamic> extra = const {}}) => {
  'type': 'object',
  'properties': {
    'text': {'type': 'string', 'minLength': 1},
    ...extra,
  },
  'required': ['text'],
  'additionalProperties': false,
};

FishMcpToolDefinition tool({
  String name = 'text_to_speech',
  String? description,
  Map<String, dynamic>? schema,
}) => FishMcpToolDefinition(
  name: name,
  description: description,
  inputSchema: schema ?? textSchema(),
);

Matcher failureWith(String code) =>
    isA<FishMcpException>().having((error) => error.code, 'code', code);

CallToolResult contentResult(Content block) => CallToolResult(content: [block]);

void main() {
  group('model evidence uses explicit response metadata only', () {
    for (final key in const [
      'model',
      'model_id',
      'modelId',
      'model_name',
      'modelName',
      'actual_model',
      'used_model',
    ]) {
      test('reads $key from nested generation metadata', () {
        expect(
          fishMcpReportedModel(
            CallToolResult(
              content: const [],
              structuredContent: {
                'result': {
                  'data': [
                    {
                      'generation': {
                        'metadata': {key: 'drama-3'},
                      },
                    },
                  ],
                },
              },
            ),
          ),
          'drama-3',
        );
      });
    }

    test('reads meta, extra, and text JSON without scanning prose', () {
      for (final result in [
        const CallToolResult(content: [], meta: {'model': 's2.1-pro'}),
        const CallToolResult(
          content: [],
          extra: {
            'metadata': {'used_model': 's2.1-pro'},
          },
        ),
        const CallToolResult(
          content: [
            TextContent(
              text: '{"result":{"metadata":{"actual_model":"s2.1-pro"}}}',
            ),
          ],
        ),
      ]) {
        expect(fishMcpReportedModel(result), 's2.1-pro');
      }
      expect(
        fishMcpReportedModel(
          const CallToolResult(
            content: [TextContent(text: 'Generated with model drama-3')],
            structuredContent: {
              'description': 'The model is drama-3',
              'voice_name': 's2.1-pro',
              'voice': {'model': 's2.1-pro'},
              'request': {'model': 'drama-3'},
              'input': {'model': 'drama-3'},
            },
          ),
        ),
        isNull,
      );
    });

    test('nested actual model takes precedence over a wrapper model echo', () {
      expect(
        fishMcpReportedModel(
          const CallToolResult(
            content: [],
            structuredContent: {
              'model': 'drama-3',
              'generation': {'actual_model': 's2.1-pro'},
            },
          ),
        ),
        's2.1-pro',
      );
    });

    test('explicit used model takes precedence across response sources', () {
      expect(
        fishMcpReportedModel(
          const CallToolResult(
            content: [
              TextContent(text: '{"result":{"used_model":"s2.1-pro"}}'),
            ],
            structuredContent: {'model': 'drama-3'},
          ),
        ),
        's2.1-pro',
      );
    });

    test('keeps actual model precedence and rejects unsafe or long labels', () {
      expect(
        fishMcpReportedModel(
          const CallToolResult(
            content: [],
            structuredContent: {
              'model': 'generic-wrapper',
              'actual_model': 'drama-3',
            },
          ),
        ),
        'drama-3',
      );
      for (final value in [
        '',
        'https://fish.audio/audio.mp3?token=do-not-show',
        'Bearer do-not-show',
        'drama-3\nPRIVATE_DIALOGUE',
        'x' * 97,
      ]) {
        expect(
          fishMcpReportedModel(
            CallToolResult(
              content: const [],
              structuredContent: {'model': value},
            ),
          ),
          isNull,
        );
      }
      expect(fishMcpModelDiagnosticLabel('  drama-3  '), 'drama-3');
      expect(
        fishMcpModelDiagnosticLabel('https://fish.audio/model?token=secret'),
        '[REDACTED]',
      );
    });
  });

  group('MCP errors preserve evidence without exposing credentials', () {
    test(
      'structured tool failure keeps code, message, status and request ID',
      () {
        final result = CallToolResult(
          content: const [TextContent(text: 'outer generic error')],
          isError: true,
          structuredContent: {
            'error': {
              'code': 'plan_denied',
              'message': 'The plan is unavailable.',
            },
            'status_code': 402,
            'request_id': 'req-local-001',
          },
        );
        final error = FishMcpException.fromToolResult(result, stage: 'tool');
        expect(error.toJson(), {
          'stage': 'tool',
          'code': 'plan_denied',
          'message': 'The plan is unavailable.',
          'status': 402,
          'request_id': 'req-local-001',
          'outcome_unknown': false,
          'generation_submitted': true,
        });
        expect(
          () => parseFishMcpAudioResult(result),
          throwsA(failureWith('plan_denied')),
        );
      },
    );

    test(
      'JSON in TextContent and metadata headers retain the service error',
      () {
        final result = CallToolResult(
          content: [
            TextContent(
              text: jsonEncode({
                'error': 'payment_required',
                'message': 'Synthetic account restriction',
                'status': '402',
              }),
            ),
          ],
          isError: true,
          meta: {
            'headers': {'X-Request-ID': 'req-header'},
          },
        );
        final error = FishMcpException.fromToolResult(result);
        expect(error.message, 'Synthetic account restriction');
        expect(error.code, 'payment_required');
        expect(error.status, 402);
        expect(error.requestId, 'req-header');
      },
    );

    test(
      'HTTP transport errors retain a distinct stage and unknown outcome',
      () {
        final error = FishMcpException.fromCause(
          McpError(
            0,
            'Error POSTing to endpoint (HTTP 503): '
            '{"error":{"code":"upstream_unavailable","message":"Service unavailable"},'
            '"request_id":"req-503"}',
          ),
          stage: 'transport',
          outcomeUnknown: true,
        );
        expect(error.stage, 'transport');
        expect(error.code, 'upstream_unavailable');
        expect(error.status, 503);
        expect(error.requestId, 'req-503');
        expect(error.message, 'Service unavailable');
        expect(error.outcomeUnknown, isTrue);
        expect(error.toString(), contains('勿自动重试'));
      },
    );

    test('a protocol exception is not flattened by another catch boundary', () {
      final original = FishMcpException(
        stage: 'audio_result',
        code: 'missing',
        message: 'Missing audio',
      );
      expect(
        FishMcpException.fromCause(original, stage: 'transport'),
        same(original),
      );
    });

    test('safe text keeps errors but scrubs OAuth, headers and signed URLs', () {
      const secret = 'do-not-show-this-value';
      final text = redactFishMcpText(
        'Bearer $secret; access_token="$secret", '
        'refresh_token=$secret; code_verifier=$secret; '
        'Cookie="$secret"; client_secret=$secret; '
        'https://user:$secret@api.fish.audio/audio.mp3?token=$secret&code=$secret',
      );
      expect(text, isNot(contains(secret)));
      expect(text, isNot(contains('user:')));
      expect(text, contains('https://api.fish.audio/audio.mp3'));
      expect(
        redactFishMcpValue({
          'error': {'code': 'payment_required', 'message': 'denied'},
          'accessToken': secret,
          'Authorization': 'Bearer $secret',
          'nested': [
            {'refresh_token': secret, 'request_id': 'req-safe'},
          ],
        }),
        {
          'error': {'code': 'payment_required', 'message': 'denied'},
          'accessToken': '[REDACTED]',
          'Authorization': '[REDACTED]',
          'nested': [
            {'refresh_token': '[REDACTED]', 'request_id': 'req-safe'},
          ],
        },
      );
    });

    test('a failed tool without details remains readable', () {
      final error = FishMcpException.fromToolResult(
        const CallToolResult(content: [], isError: true),
      );
      expect(error.stage, 'tool_call');
      expect(error.message, contains('未提供错误说明'));
    });

    test('an unstructured tool error preserves a labelled request ID', () {
      final error = FishMcpException.fromToolResult(
        const CallToolResult(
          content: [
            TextContent(text: 'Service unavailable. Request ID: req-text-123'),
          ],
          isError: true,
        ),
      );
      expect(error.requestId, 'req-text-123');
      expect(error.message, contains('Service unavailable'));
    });
  });

  group('tool identification and cloud-validated parameter mapping', () {
    test('canonical text_to_speech wins without relying on descriptions', () {
      final expected = tool();
      expect(
        selectFishMcpTtsTool([
          tool(name: 'generate_speech'),
          tool(name: 'get_tts_credits', description: 'TTS speech synthesis'),
          tool(name: 'search', description: 'text-to-speech and TTS search'),
          expected,
        ]),
        same(expected),
      );
    });

    test('namespaces work and query tools cannot masquerade as TTS', () {
      final expected = tool(name: 'fish.audio/text-to-speech');
      expect(
        selectFishMcpTtsTool([
          tool(name: 'search_text_to_speech'),
          tool(name: 'get_text_to_speech'),
          tool(
            name: 'speech_credit_balance',
            description: 'TTS speech synthesis',
          ),
          expected,
        ]),
        same(expected),
      );
      expect(
        selectFishMcpTtsTool([
          tool(
            name: 'unrelated',
            description: 'TTS text-to-speech speech synthesis',
          ),
        ]),
        isNull,
      );
    });

    test('a generation tool with incomplete text schema stays selectable', () {
      final definition = tool(
        schema: {
          'type': 'object',
          'properties': {
            'voice_id': {'type': 'string'},
          },
        },
      );
      expect(selectFishMcpTtsTool([definition]), same(definition));
      expect(buildFishMcpTtsArguments(tool: definition, text: 'Hello'), {
        'text': 'Hello',
      });
    });

    test(
      'declared aliases map and configured voice has a canonical fallback',
      () {
        final definition = tool(
          schema: {
            'type': 'object',
            'properties': {
              'input_text': {'type': 'string'},
              'voice_id': {'type': 'string'},
              'model_id': {
                'type': 'string',
                'enum': ['allowed-model'],
              },
              'lang': {'type': 'string'},
              'output_format': {
                'type': 'string',
                'enum': ['mp3'],
              },
              'prosody_speed': {'type': 'number', 'minimum': 0.5, 'maximum': 2},
            },
            'required': ['input_text', 'voice_id'],
            'additionalProperties': false,
          },
        );
        expect(
          buildFishMcpTtsArguments(
            tool: definition,
            text: 'こんにちは',
            voice: 'voice-test',
            model: 'allowed-model',
            language: 'ja',
            format: 'mp3',
            speed: 1.1,
          ),
          {
            'input_text': 'こんにちは',
            'voice_id': 'voice-test',
            'model_id': 'allowed-model',
            'lang': 'ja',
            'output_format': 'mp3',
            'prosody_speed': 1.1,
          },
        );
        expect(
          buildFishMcpTtsArguments(
            tool: tool(),
            text: 'Hello',
            voice: 'unused-voice',
            language: 'ja',
            format: 'wav',
            speed: 1,
          ),
          {'text': 'Hello', 'voice_id': 'unused-voice'},
        );
      },
    );

    test('undeclared models are never added to ordinary TTS arguments', () {
      expect(
        buildFishMcpTtsArguments(tool: tool(), text: 'Hello', model: 'drama-3'),
        {'text': 'Hello'},
      );
      final raw = textSchema()..['additionalProperties'] = false;
      expect(
        buildFishMcpTtsArguments(
          tool: tool(schema: raw..['additionalProperties'] = true),
          text: 'Hello',
          model: 'drama-3',
        ),
        {'text': 'Hello'},
      );
      expect(
        buildFishMcpTtsArguments(
          tool: tool(
            schema: textSchema(
              extra: {
                'model': {
                  'type': 'string',
                  'enum': ['server-model'],
                },
              },
            ),
          ),
          text: 'Hello',
          model: 'drama-3',
        ),
        {'text': 'Hello', 'model': 'drama-3'},
      );
    });

    for (final alias in ['model', 'model_id', 'modelId']) {
      test('model uses declared $alias without enum rejection', () {
        expect(
          buildFishMcpTtsArguments(
            tool: tool(
              schema: textSchema(
                extra: {
                  alias: {
                    'type': 'string',
                    'enum': ['old-model'],
                  },
                },
              ),
            ),
            text: 'Hello',
            model: 'drama-3',
          ),
          {'text': 'Hello', alias: 'drama-3'},
        );
      });
    }

    test('cached required fields, length and numeric constraints do not reject locally', () {
      final requiredUnknown = textSchema()
        ..['required'] = ['text', 'billing_mode'];
      expect(
        buildFishMcpTtsArguments(
          tool: tool(schema: requiredUnknown),
          text: 'Hi',
        ),
        {'text': 'Hi'},
      );
      expect(buildFishMcpTtsArguments(tool: tool(), text: ''), {'text': ''});
      expect(
        buildFishMcpTtsArguments(
          tool: tool(
            schema: textSchema(
              extra: {
                'speed': {'type': 'number', 'minimum': 0.8, 'maximum': 1.2},
              },
            ),
          ),
          text: 'Hello',
          speed: 1.5,
        ),
        {'text': 'Hello', 'speed': 1.5},
      );
    });

    for (final expected in ['ja', 'ja-JP', 'Japanese']) {
      test('Japanese aliases map to the real $expected enum', () {
        final arguments = buildFishMcpTtsArguments(
          tool: tool(
            schema: textSchema(
              extra: {
                'language': {
                  'type': 'string',
                  'enum': [expected, 'English'],
                },
              },
            ),
          ),
          text: 'こんにちは',
          language: 'ja',
        );
        expect(arguments['language'], expected);
      });
    }

    test(
      'optional unsupported language uses the default with an explicit note',
      () {
        final omitted = <String>[];
        final arguments = buildFishMcpTtsArguments(
          tool: tool(
            schema: textSchema(
              extra: {
                'language': {
                  'type': 'string',
                  'enum': ['auto'],
                },
              },
            ),
          ),
          text: 'こんにちは',
          language: 'ja',
          onOmittedOptionalField: (field, explanation) =>
              omitted.add('$field:$explanation'),
        );
        expect(arguments, {'text': 'こんにちは'});
        expect(omitted.single, contains('language:'));
        expect(omitted.single, contains('服务默认语言'));
      },
    );

    test('required unmatched language passes through for cloud validation', () {
      final schema = textSchema(
        extra: {
          'language': {
            'type': 'string',
            'enum': ['English'],
          },
        },
      )..['required'] = ['text', 'language'];
      expect(
        buildFishMcpTtsArguments(
          tool: tool(schema: schema),
          text: 'こんにちは',
          language: 'ja',
        ),
        {'text': 'こんにちは', 'language': 'ja'},
      );
    });

    test(
      'local schema references and allOf still provide parameter aliases',
      () {
        final definition = tool(
          schema: {
            'type': 'object',
            r'$ref': r'#/$defs/input',
            r'$defs': {
              'input': {
                'allOf': [
                  {
                    'properties': {
                      'text': {'type': 'string', 'minLength': 2},
                    },
                    'required': ['text'],
                  },
                  {
                    'properties': {
                      'language': {
                        'type': 'string',
                        'enum': ['Japanese'],
                      },
                    },
                  },
                ],
              },
            },
          },
        );
        expect(
          buildFishMcpTtsArguments(
            tool: definition,
            text: 'こんにちは',
            language: 'ja',
          ),
          {'text': 'こんにちは', 'language': 'Japanese'},
        );
        expect(buildFishMcpTtsArguments(tool: definition, text: 'x'), {
          'text': 'x',
        });
      },
    );

    test('unresolved external schema references do not reject generation', () {
      final definition = tool(
        schema: {
          ...textSchema(),
          r'$ref': 'https://schema.example.invalid/input.json',
        },
      );
      expect(buildFishMcpTtsArguments(tool: definition, text: 'Hello'), {
        'text': 'Hello',
      });
    });
  });

  group('audio result parsing without network calls', () {
    final bytes = utf8.encode('synthetic-audio');
    final encoded = base64Encode(bytes);

    test('AudioContent becomes inline bytes', () {
      final payload = parseFishMcpAudioResult(
        contentResult(AudioContent(data: encoded, mimeType: 'audio/wav')),
      );
      expect(payload.bytes, bytes);
      expect(payload.uri, isNull);
      expect(payload.mimeType, 'audio/wav');
    });

    test('embedded blob and embedded text resources are understood', () {
      final blob = parseFishMcpAudioResult(
        contentResult(
          EmbeddedResource(
            resource: BlobResourceContents(
              uri: 'fish://generated/1.wav',
              blob: encoded,
              mimeType: 'audio/wav',
            ),
          ),
        ),
      );
      expect(blob.bytes, bytes);
      final text = parseFishMcpAudioResult(
        contentResult(
          const EmbeddedResource(
            resource: TextResourceContents(
              uri: 'fish://generated/1',
              mimeType: 'application/json',
              text: '{"audio_url":"https://cdn.fish.audio/generated.mp3"}',
            ),
          ),
        ),
      );
      expect(text.uri.toString(), 'https://cdn.fish.audio/generated.mp3');
    });

    test('ResourceLink may identify an audio MIME without a filename', () {
      final payload = parseFishMcpAudioResult(
        contentResult(
          const ResourceLink(
            uri: 'https://api.fish.audio/audio/123',
            name: 'Generated speech',
            mimeType: 'audio/mpeg',
          ),
        ),
      );
      expect(payload.uri.toString(), 'https://api.fish.audio/audio/123');
    });

    test('structured and text JSON handle nested audio arrays and Base64', () {
      final structured = parseFishMcpAudioResult(
        CallToolResult(
          content: const [],
          structuredContent: {
            'output': {
              'files': [
                {
                  'uri': 'https://cdn.fish.audio/voice.ogg',
                  'mime_type': 'audio/ogg',
                },
              ],
            },
          },
        ),
      );
      expect(structured.mimeType, 'audio/ogg');
      final text = parseFishMcpAudioResult(
        contentResult(
          TextContent(
            text: jsonEncode({
              'result': {'audio_base64': encoded, 'mime_type': 'audio/wav'},
            }),
          ),
        ),
      );
      expect(text.bytes, bytes);
    });

    for (final text in [
      'https://cdn.fish.audio/voice.mp3',
      '[Download audio](https://cdn.fish.audio/voice.mp3)',
      'Created: ![语音](https://cdn.fish.audio/voice.mp3)',
      '[Listen](<https://cdn.fish.audio/voice.mp3> "Generated speech")',
      '[audio](https://api.fish.audio/download/123)',
      'Generated successfully. Audio: https://cdn.fish.audio/voice.mp3',
    ]) {
      test('text output parses $text', () {
        final payload = parseFishMcpAudioResult(
          contentResult(TextContent(text: text)),
        );
        expect(payload.uri?.scheme, 'https');
        expect(payload.mimeType, 'audio/mpeg');
      });
    }

    test('data audio URI becomes inline bytes', () {
      expect(
        parseFishMcpAudioResult(
          contentResult(TextContent(text: 'data:audio/wav;base64,$encoded')),
        ).bytes,
        bytes,
      );
    });

    test('a non-audio resource is not downloaded accidentally', () {
      expect(
        () => parseFishMcpAudioResult(
          contentResult(
            const ResourceLink(
              uri: 'https://fish.audio/app/developers',
              name: 'Account',
              mimeType: 'text/html',
            ),
          ),
        ),
        throwsA(failureWith('audio_not_found')),
      );
    });

    test(
      'missing audio error names content kinds without dumping the response',
      () {
        expect(
          () => parseFishMcpAudioResult(
            contentResult(
              const TextContent(text: 'Secret or unrelated response body'),
            ),
          ),
          throwsA(
            isA<FishMcpException>()
                .having((error) => error.code, 'code', 'audio_not_found')
                .having(
                  (error) => error.message,
                  'message',
                  allOf(contains('text'), isNot(contains('Secret'))),
                ),
          ),
        );
      },
    );

    test(
      'invalid Base64, empty bytes, and oversized audio have distinct errors',
      () {
        expect(
          () => parseFishMcpAudioResult(
            contentResult(
              const AudioContent(
                data: '!!!bad-base64!!!',
                mimeType: 'audio/mpeg',
              ),
            ),
          ),
          throwsA(failureWith('invalid_audio_base64')),
        );
        expect(
          () => parseFishMcpAudioResult(
            contentResult(const AudioContent(data: '', mimeType: 'audio/mpeg')),
          ),
          throwsA(failureWith('empty_or_oversized_audio')),
        );
        expect(
          () => parseFishMcpAudioResult(
            contentResult(
              AudioContent(
                data: base64Encode(List.filled(100, 0)),
                mimeType: 'audio/mpeg',
              ),
            ),
            maximumInlineBytes: 4,
          ),
          throwsA(failureWith('audio_payload_too_large')),
        );
      },
    );

    for (final address in [
      'http://cdn.fish.audio/file.mp3',
      'https://fish.audio.attacker.invalid/file.mp3',
      'https://unrelated.invalid/file.mp3?token=do-not-expose',
      'https://user:private@cdn.fish.audio/file.mp3',
      'https://cdn.fish.audio:8443/file.mp3',
    ]) {
      test('unsafe or untrusted download is rejected: $address', () {
        expect(
          () => parseFishMcpAudioResult(
            contentResult(TextContent(text: address)),
          ),
          throwsA(
            isA<FishMcpException>()
                .having((error) => error.stage, 'stage', 'audio_url')
                .having(
                  (error) => error.message,
                  'message',
                  isNot(contains('do-not-expose')),
                ),
          ),
        );
      });
    }

    test(
      'a verified CDN can be configured explicitly with an exact hostname',
      () {
        const policy = FishMcpAudioUrlPolicy(
          additionalHosts: {'audio.verified.example'},
        );
        final result = contentResult(
          const TextContent(text: 'https://audio.verified.example/file.mp3'),
        );
        expect(
          parseFishMcpAudioResult(result, policy: policy).uri?.host,
          'audio.verified.example',
        );
        expect(
          () => policy.validate(
            Uri.parse('https://evil.audio.verified.example/file.mp3'),
          ),
          throwsA(failureWith('untrusted_audio_host')),
        );
      },
    );
  });
}
