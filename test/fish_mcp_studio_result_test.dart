import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:ryza_chat_mvp/src/fish_mcp_protocol.dart';
import 'package:ryza_chat_mvp/src/fish_mcp_service.dart';
import 'package:ryza_chat_mvp/src/fish_mcp_studio.dart';

// Every tool result is a local fixture. These tests never connect to Fish,
// download audio, or submit a credit-consuming generation.
const _project = 'project-current';
const _chapter = 'chapter-current';
const _block = 'block-current';
const _audio = 'https://platform.r2.fish.audio/local/current.wav';
const _oldAudio = 'https://platform.r2.fish.audio/local/stale.wav';

CallToolResult _data(Map<String, dynamic> value) =>
    CallToolResult(content: const [], structuredContent: value);

Map<String, dynamic> _target({
  String? anchor = _block,
  String? status,
  String audio = _audio,
}) => {'anchor': ?anchor, 'status': ?status, 'audio_url': audio};

CallToolResult _readAudio({
  bool changed = false,
  String anchor = _block,
  String? status,
}) => _data({
  'blocks': [
    {
      'anchor': anchor,
      'status': ?status,
      'data': {'audio_url': _audio, 'changed': changed},
    },
  ],
});

class _ResultClient extends McpClient {
  _ResultClient({required this.initial, this.reads = const [], this.beforeRead})
    : super(const Implementation(name: 'studio-result-fixture', version: '1'));

  final CallToolResult initial;
  final List<CallToolResult> reads;
  final void Function(int count)? beforeRead;
  final requests = <CallToolRequest>[];

  List<CallToolRequest> named(String name) =>
      requests.where((request) => request.name == name).toList();

  List<CallToolRequest> get paid =>
      named('studio_generate')
          .where((request) => request.arguments['dry_run'] != true)
          .toList();

  @override
  Future<CallToolResult> callTool(
    CallToolRequest params, {
    RequestOptions? options,
  }) async {
    requests.add(params);
    switch (params.name) {
      case 'studio_help':
        return _data({'overview': 'local result fixture'});
      case 'studio_create_project':
        return _data({
          'project_id': _project,
          'chapters': [
            {'anchor': _chapter},
          ],
        });
      case 'studio_update_project':
        return _data({'project_id': _project, ...params.arguments});
      case 'studio_project':
        return _data({
          'project_id': _project,
          'default_backend': 'drama-3',
          'scene_preset': 'off',
        });
      case 'studio_write_blocks':
        return _data({
          'results': [
            {'anchor': _block},
          ],
        });
      case 'studio_generate':
        if (params.arguments['dry_run'] == true) {
          return _data({
            'blocks_to_generate': 1,
            'cached': 0,
            'estimated_credits': 12,
            'balance': 1000,
          });
        }
        return initial;
      case 'studio_read_blocks':
        final count = named('studio_read_blocks').length;
        beforeRead?.call(count);
        if (reads.isEmpty) {
          return _data({'blocks': <Object>[]});
        }
        return reads[(count - 1).clamp(0, reads.length - 1)];
      default:
        fail('Unexpected tool ${params.name}');
    }
  }

  @override
  Future<void> close() async {}
}

class _ResultHarness {
  _ResultHarness({
    required CallToolResult initial,
    List<CallToolResult> reads = const [],
    bool canRead = true,
    void Function(int count)? beforeRead,
  }) : client = _ResultClient(
         initial: initial,
         reads: reads,
         beforeRead: beforeRead,
       ) {
    session = FishMcpStudioSession(
      client: client,
      ensureCurrent: checkCurrent,
      readBlocksAvailable: canRead,
      maximumReadAttempts: 3,
      readInterval: Duration.zero,
    );
  }

  final _ResultClient client;
  late final FishMcpStudioSession session;
  bool active = true;
  bool connected = true;
  int submitted = 0;
  final configured = <String>[];
  final summary = <String, Object?>{};

  void checkCurrent() {
    if (!connected) {
      throw FishMcpException(
        stage: 'connection',
        code: 'connection_changed',
        message: 'Local test disconnected',
        generationSubmitted: submitted != 0,
      );
    }
  }

  Future<CallToolResult> generate() => session.generate(
    text: '非公開のテスト本文',
    voice: 'ordinary-voice',
    model: 'drama-3',
    ensureRequestCurrent: () {
      checkCurrent();
      if (!active) {
        throw FishMcpException(
          stage: 'cancelled',
          code: 'request_cancelled',
          message: 'Local test cancelled',
          generationSubmitted: submitted != 0,
        );
      }
    },
    onSubmitted: () => submitted++,
    onConfigured: configured.add,
    onSummary: summary.addAll,
  );

  void expectOneGeneration() {
    expect(submitted, 1);
    expect(client.paid, hasLength(1));
    expect(client.paid.single.arguments, {
      'project_id': _project,
      'blocks': [_block],
    });
    expect(client.named('text_to_speech'), isEmpty);
  }
}

Future<FishMcpException> _failure(Future<CallToolResult> result) async {
  try {
    await result;
  } on FishMcpException catch (error) {
    return error;
  }
  fail('Expected FishMcpException');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final compatibleReadSchema = <String, dynamic>{
    'type': 'object',
    'properties': {
      'project_id': {'type': 'string'},
      'chapter': {'type': 'string'},
    },
    'required': ['project_id', 'chapter'],
  };
  for (final scenario
      in <({String name, Map<String, dynamic>? schema, bool available})>[
        (name: 'tool absent', schema: null, available: false),
        (
          name: 'exact read contract',
          schema: compatibleReadSchema,
          available: true,
        ),
        (
          name: 'optional read parameters',
          schema: {...compatibleReadSchema}..remove('required'),
          available: true,
        ),
        (
          name: 'additional required field',
          schema: {
            ...compatibleReadSchema,
            'required': ['project_id', 'chapter', 'generate'],
          },
          available: false,
        ),
        (
          name: 'additional required field through allOf',
          schema: {
            ...compatibleReadSchema,
            'allOf': [
              {
                'required': ['generate'],
              },
            ],
          },
          available: false,
        ),
        (
          name: 'additional required field through a local ref',
          schema: {
            ...compatibleReadSchema,
            r'$defs': {
              'readContract': {
                'required': ['generate'],
              },
            },
            'allOf': [
              {r'$ref': r'#/$defs/readContract'},
            ],
          },
          available: false,
        ),
        (
          name: 'malformed required declaration',
          schema: {...compatibleReadSchema, 'required': 'project_id'},
          available: false,
        ),
        (
          name: 'missing read properties',
          schema: {'type': 'object', 'properties': <String, Object?>{}},
          available: false,
        ),
        for (final invalidField in ['project_id', 'chapter'])
          (
            name: 'non-string $invalidField',
            schema: {
              ...compatibleReadSchema,
              'properties': {
                'project_id': {'type': 'string'},
                'chapter': {'type': 'string'},
                invalidField: {'type': 'integer'},
              },
            },
            available: false,
          ),
      ]) {
    test(
      'free read capability requires compatible schema: ${scenario.name}',
      () {
        final client = _ResultClient(initial: _data({}));
        final downloader = MockClient((_) async {
          fail('Capability inspection must not download or generate audio');
        });
        final service = FishMcpService.forTesting(
          client: client,
          downloadClient: downloader,
          temporaryDirectory: () async => Directory.systemTemp,
        );
        addTearDown(service.dispose);
        service.tools = [
          if (scenario.schema case final schema?)
            FishMcpToolInfo(
              name: 'studio_read_blocks',
              description: 'Read-only local fixture',
              inputSchema: schema,
            ),
        ];
        expect(service.studioReadBlocksAvailable, scenario.available);
        expect(client.requests, isEmpty);
      },
    );
  }

  for (final rootStatus in <String?>[null, 'done']) {
    for (final blockStatus in <String?>[null, 'done']) {
      test(
        'unique current audio completes with root=$rootStatus block=$blockStatus',
        () async {
          final harness = _ResultHarness(
            initial: _data({
              'status': ?rootStatus,
              'results': [_target(status: blockStatus)],
            }),
          );
          final result = await harness.generate();
          expect(parseFishMcpAudioResult(result).uri.toString(), _audio);
          harness.expectOneGeneration();
          expect(harness.client.named('studio_read_blocks'), isEmpty);
        },
      );
    }
  }

  for (final shape in ['single result', 'root', 'wrapped root', 'inline']) {
    for (final canRead in [true, false]) {
      test(
        '$shape without target identity ${canRead ? 'uses a readback' : 'is rejected without a read tool'}',
        () async {
          final unlabelled = switch (shape) {
            'single result' => _data({
              'results': [_target(anchor: null, audio: _oldAudio)],
            }),
            'wrapped root' => _data({
              'result': {'status': 'done', 'audio_url': _oldAudio},
            }),
            'inline' => CallToolResult(
              content: [
                AudioContent(
                  data: base64Encode([1, 2, 3]),
                  mimeType: 'audio/wav',
                ),
              ],
            ),
            _ => _data({
              'status': 'done',
              'project_id': _project,
              'chapter_anchor': _chapter,
              'audio_url': _oldAudio,
            }),
          };
          final harness = _ResultHarness(
            initial: unlabelled,
            reads: [_readAudio()],
            canRead: canRead,
          );
          if (canRead) {
            final result = await harness.generate();
            expect(parseFishMcpAudioResult(result).uri.toString(), _audio);
            expect(jsonEncode(result.toJson()), isNot(contains(_oldAudio)));
            expect(harness.client.named('studio_read_blocks'), hasLength(1));
          } else {
            final error = await _failure(harness.generate());
            expect(error.code, 'studio_identity_unconfirmed');
            expect(error.generationSubmitted, isTrue);
            expect(error.outcomeUnknown, isTrue);
            expect(error.allowsRestFallback, isFalse);
          }
          harness.expectOneGeneration();
        },
      );
    }
  }

  for (final key in ['dirty', 'changed']) {
    for (final flag in [true, 1, 1.0]) {
      test('$key=$flag cannot return stale target audio', () async {
        final harness = _ResultHarness(
          initial: _data({
            'results': [
              {
                ..._target(audio: _oldAudio),
                'data': {key: flag},
              },
            ],
          }),
          reads: [_readAudio()],
        );
        final result = await harness.generate();
        expect(parseFishMcpAudioResult(result).uri.toString(), _audio);
        expect(harness.client.named('studio_read_blocks'), hasLength(1));
        harness.expectOneGeneration();
      });
    }
    for (final flag in [false, 0, 0.0]) {
      test('$key=$flag accepts exact completed target', () async {
        final harness = _ResultHarness(
          initial: _data({
            'results': [
              {..._target(), key: flag},
            ],
          }),
        );
        expect(
          parseFishMcpAudioResult(await harness.generate()).uri.toString(),
          _audio,
        );
        expect(harness.client.named('studio_read_blocks'), isEmpty);
        harness.expectOneGeneration();
      });
    }
    for (final flag in <Object?>['true', 'false', null, -1, 0.5, {}, []]) {
      test('unknown $key=$flag rejects potentially stale audio', () async {
        final harness = _ResultHarness(
          initial: _data({
            'results': [
              {..._target(audio: _oldAudio), key: flag},
            ],
          }),
        );
        final error = await _failure(harness.generate());
        expect(error.generationSubmitted, isTrue);
        expect(error.allowsRestFallback, isFalse);
        expect(harness.client.named('studio_read_blocks'), isEmpty);
        harness.expectOneGeneration();
      });
    }
  }

  test(
    'numeric chapter dirty count waits for the exact clean target',
    () async {
      final harness = _ResultHarness(
        initial: _data({
          'dirty': 2,
          'results': [_target(audio: _oldAudio)],
        }),
        reads: [_readAudio()],
      );
      expect(
        parseFishMcpAudioResult(await harness.generate()).uri.toString(),
        _audio,
      );
      expect(harness.client.named('studio_read_blocks'), hasLength(1));
      harness.expectOneGeneration();
    },
  );

  test(
    'only target duration metadata survives normalization and diagnostics',
    () async {
      final harness = _ResultHarness(
        initial: _data({
          'duration_s': 71,
          'metadata': {'duration_ms': 71000},
          'results': [
            {
              ..._target(),
              'data': {
                'duration_s': 8.25,
                'metadata': {'duration_ms': 8250},
              },
            },
          ],
        }),
      );
      final result = await harness.generate();
      final output =
          ((result.structuredContentJson!.toJson() as Map)['results'] as List)
                  .single
              as Map;
      expect(output['duration_s'], 8.25);
      expect(output['duration_ms'], 8250);
      expect(harness.summary['studio_result_target_duration_s'], 8.25);
      expect(harness.summary['studio_result_target_duration_ms'], 8250);
      expect(jsonEncode(harness.summary), isNot(contains(_audio)));
      harness.expectOneGeneration();
    },
  );

  test(
    'unidentified single result still honors explicit generation failure',
    () async {
      final harness = _ResultHarness(
        initial: _data({
          'results': [
            _target(anchor: null, status: 'failed', audio: _oldAudio),
          ],
        }),
        reads: [_readAudio()],
      );
      final error = await _failure(harness.generate());
      expect(error.code, 'studio_generation_failed');
      expect(harness.client.named('studio_read_blocks'), isEmpty);
      harness.expectOneGeneration();
    },
  );

  test('chapter duration is never presented as target duration', () async {
    final harness = _ResultHarness(
      initial: _data({
        'duration_s': 71,
        'results': [_target()],
      }),
    );
    final result = await harness.generate();
    expect(jsonEncode(result.toJson()), isNot(contains('duration_s')));
    expect(
      harness.summary.containsKey('studio_result_target_duration_s'),
      isFalse,
    );
    harness.expectOneGeneration();
  });

  for (final duration in <Object?>['71', -1, null]) {
    test('invalid target duration $duration is rejected', () async {
      final harness = _ResultHarness(
        initial: _data({
          'results': [
            {..._target(), 'duration_s': duration},
          ],
        }),
      );
      final error = await _failure(harness.generate());
      expect(error.generationSubmitted, isTrue);
      expect(error.allowsRestFallback, isFalse);
      harness.expectOneGeneration();
    });
  }

  test(
    'JSON text result does not require an invented root completion status',
    () async {
      final harness = _ResultHarness(
        initial: CallToolResult(
          content: [
            TextContent(
              text: jsonEncode({
                'results': [_target()],
              }),
            ),
          ],
        ),
      );
      final result = await harness.generate();
      expect(parseFishMcpAudioResult(result).uri.toString(), _audio);
      harness.expectOneGeneration();
    },
  );

  test('normalized result excludes stale root URL and text content', () async {
    final harness = _ResultHarness(
      initial: CallToolResult(
        content: const [TextContent(text: _oldAudio)],
        structuredContent: {
          'audio_url': _oldAudio,
          'results': [
            {..._target(), 'actual_model': 'drama-3'},
          ],
        },
      ),
    );
    final result = await harness.generate();
    expect(parseFishMcpAudioResult(result).uri.toString(), _audio);
    expect(fishMcpReportedModel(result), 'drama-3');
    expect(jsonEncode(result.toJson()), isNot(contains(_oldAudio)));
    harness.expectOneGeneration();
  });

  for (final field in ['model_name', 'modelName']) {
    for (final nested in [false, true]) {
      test(
        'normalization preserves $field from ${nested ? 'metadata' : 'the block'}',
        () async {
          final harness = _ResultHarness(
            initial: _data({
              'results': [
                {
                  ..._target(),
                  if (nested)
                    'metadata': {field: 'drama-3'}
                  else
                    field: 'drama-3',
                },
              ],
            }),
          );
          final result = await harness.generate();
          expect(parseFishMcpAudioResult(result).uri.toString(), _audio);
          expect(fishMcpReportedModel(result), 'drama-3');
          harness.expectOneGeneration();
        },
      );
    }
  }

  test(
    'selects the current target while excluding another result block',
    () async {
      final harness = _ResultHarness(
        initial: _data({
          'results': [
            _target(anchor: 'old-block', audio: _oldAudio),
            _target(),
          ],
        }),
      );
      final result = await harness.generate();
      expect(parseFishMcpAudioResult(result).uri.toString(), _audio);
      expect(jsonEncode(result.toJson()), isNot(contains(_oldAudio)));
      harness.expectOneGeneration();
    },
  );

  for (final invalid in [
    {
      'results': [_target(anchor: 'different-block')],
    },
    {
      'project_id': 'different-project',
      'results': [_target()],
    },
    {
      'results': [_target(), _target(audio: _oldAudio)],
    },
  ]) {
    test(
      'rejects conflicting project or target identity: ${invalid.keys}',
      () async {
        final harness = _ResultHarness(initial: _data(invalid));
        final error = await _failure(harness.generate());
        expect(error.generationSubmitted, isTrue);
        expect(error.allowsRestFallback, isFalse);
        harness.expectOneGeneration();
        expect(harness.client.named('studio_read_blocks'), isEmpty);
      },
    );
  }

  for (final failure in ['failed', 'error', 'cancelled']) {
    for (final atRoot in [true, false]) {
      test(
        'explicit $failure at ${atRoot ? 'root' : 'block'} overrides an audio URL',
        () async {
          final harness = _ResultHarness(
            initial: _data({
              if (atRoot) 'status': failure,
              'results': [_target(status: atRoot ? null : failure)],
            }),
          );
          final error = await _failure(harness.generate());
          expect(error.generationSubmitted, isTrue);
          expect(error.allowsRestFallback, isFalse);
          harness.expectOneGeneration();
          expect(harness.client.named('studio_read_blocks'), isEmpty);
        },
      );
    }
  }

  for (final atRoot in [true, false]) {
    test(
      'running ${atRoot ? 'root' : 'block'} with a stale URL waits for a read-only confirmation',
      () async {
        final harness = _ResultHarness(
          initial: _data({
            if (atRoot) 'status': 'running',
            'results': [
              _target(status: atRoot ? null : 'running', audio: _oldAudio),
            ],
          }),
          reads: [_readAudio()],
        );
        final result = await harness.generate();
        expect(parseFishMcpAudioResult(result).uri.toString(), _audio);
        harness.expectOneGeneration();
        expect(harness.client.named('studio_read_blocks'), hasLength(1));
        expect(harness.client.named('studio_read_blocks').single.arguments, {
          'project_id': _project,
          'chapter': _chapter,
        });
      },
    );
  }

  test('pending becomes done through bounded free reads without another generation', () async {
    final harness = _ResultHarness(
      initial: _data({'status': 'running', 'results': <Object>[]}),
      reads: [
        _data({
          'blocks': [
            {'anchor': _block, 'status': 'running'},
          ],
        }),
        _readAudio(),
      ],
    );
    final result = await harness.generate();
    expect(parseFishMcpAudioResult(result).uri.toString(), _audio);
    expect(harness.client.named('studio_read_blocks'), hasLength(2));
    expect(harness.client.named('studio_generate'), hasLength(2));
    harness.expectOneGeneration();
  });

  test('read results select only the exact current anchor', () async {
    final harness = _ResultHarness(
      initial: _data({'status': 'running', 'results': <Object>[]}),
      reads: [
        _data({
          'audio_url': _oldAudio,
          'results': [
            _target(anchor: 'old-block', audio: _oldAudio),
            _target(status: 'done'),
          ],
        }),
      ],
    );
    final result = await harness.generate();
    expect(parseFishMcpAudioResult(result).uri.toString(), _audio);
    expect(jsonEncode(result.toJson()), isNot(contains(_oldAudio)));
    harness.expectOneGeneration();
  });

  for (final readResult in [
    _data({
      'blocks': [_target(anchor: null)],
    }),
    _data({
      'blocks': [_target(anchor: 'old-block', audio: _oldAudio)],
    }),
    _readAudio(changed: true),
  ]) {
    test(
      'unidentified or stale read audio never completes the target',
      () async {
        final harness = _ResultHarness(
          initial: _data({'status': 'running', 'results': <Object>[]}),
          reads: [readResult],
        );
        final error = await _failure(harness.generate());
        expect(error.generationSubmitted, isTrue);
        expect(error.allowsRestFallback, isFalse);
        expect(harness.client.named('studio_read_blocks'), hasLength(3));
        harness.expectOneGeneration();
      },
    );
  }

  test('duplicate target anchors in a read response are rejected', () async {
    final harness = _ResultHarness(
      initial: _data({'status': 'running', 'results': <Object>[]}),
      reads: [
        _data({
          'blocks': [_target(), _target(audio: _oldAudio)],
        }),
      ],
    );
    final error = await _failure(harness.generate());
    expect(error.generationSubmitted, isTrue);
    expect(error.allowsRestFallback, isFalse);
    expect(harness.client.named('studio_read_blocks'), hasLength(1));
    harness.expectOneGeneration();
  });

  test('read project mismatch cannot return another project audio', () async {
    final harness = _ResultHarness(
      initial: _data({'status': 'running', 'results': <Object>[]}),
      reads: [
        _data({
          'project_id': 'another-project',
          'blocks': [_target()],
        }),
      ],
    );
    final error = await _failure(harness.generate());
    expect(error.generationSubmitted, isTrue);
    expect(error.allowsRestFallback, isFalse);
    expect(harness.client.named('studio_read_blocks'), hasLength(1));
    harness.expectOneGeneration();
  });

  test(
    'pending read ending in failure does not retry paid generation',
    () async {
      final harness = _ResultHarness(
        initial: _data({'status': 'running', 'results': <Object>[]}),
        reads: [
          _data({
            'blocks': [
              {'anchor': _block, 'status': 'failed'},
            ],
          }),
        ],
      );
      final error = await _failure(harness.generate());
      expect(error.generationSubmitted, isTrue);
      expect(error.allowsRestFallback, isFalse);
      expect(harness.client.named('studio_read_blocks'), hasLength(1));
      harness.expectOneGeneration();
    },
  );

  test(
    'permanent pending stops after exactly the configured free read limit',
    () async {
      final harness = _ResultHarness(
        initial: _data({'status': 'running', 'results': <Object>[]}),
        reads: [
          _data({
            'blocks': [
              {'anchor': _block, 'status': 'running'},
            ],
          }),
        ],
      );
      final error = await _failure(harness.generate());
      expect(error.generationSubmitted, isTrue);
      expect(error.allowsRestFallback, isFalse);
      expect(harness.client.named('studio_read_blocks'), hasLength(3));
      expect(harness.client.named('studio_generate'), hasLength(2));
      harness.expectOneGeneration();
    },
  );

  test('missing read capability preserves unknown outcome and never generates again', () async {
    final harness = _ResultHarness(
      initial: _data({'status': 'running', 'results': <Object>[]}),
      canRead: false,
    );
    final error = await _failure(harness.generate());
    expect(error.generationSubmitted, isTrue);
    expect(error.outcomeUnknown, isTrue);
    expect(error.allowsRestFallback, isFalse);
    expect(harness.client.named('studio_read_blocks'), isEmpty);
    harness.expectOneGeneration();
  });

  for (final disconnect in [false, true]) {
    test(
      '${disconnect ? 'disconnect' : 'cancel'} during pending read discards ready audio and stops',
      () async {
        late final _ResultHarness harness;
        harness = _ResultHarness(
          initial: _data({'status': 'running', 'results': <Object>[]}),
          reads: [_readAudio()],
          beforeRead: (_) {
            if (disconnect) {
              harness.connected = false;
            } else {
              harness.active = false;
            }
          },
        );
        final error = await _failure(harness.generate());
        expect(
          error.code,
          disconnect ? 'connection_changed' : 'request_cancelled',
        );
        expect(error.allowsRestFallback, isFalse);
        expect(harness.client.named('studio_read_blocks'), hasLength(1));
        harness.expectOneGeneration();
      },
    );
  }

  test('result summaries exclude text, credentials, and signed URLs', () async {
    const secret = 'signed-secret-that-must-not-be-logged';
    final harness = _ResultHarness(
      initial: _data({
        'status': 'running',
        'text': '非公開のテスト本文',
        'authorization': 'Bearer $secret',
        'results': <Object>[],
      }),
      reads: [
        _data({
          'blocks': [
            {
              'anchor': _block,
              'data': {
                'audio_url': '$_audio?token=$secret',
                'changed': false,
                'actual_model': 'drama-3',
              },
            },
          ],
        }),
      ],
    );
    final result = await harness.generate();
    expect(parseFishMcpAudioResult(result).uri?.path, '/local/current.wav');
    final summary = jsonEncode(harness.summary);
    expect(summary, isNot(contains(secret)));
    expect(summary, isNot(contains('非公開のテスト本文')));
    expect(summary, isNot(contains(_audio)));
    harness.expectOneGeneration();
  });
}
