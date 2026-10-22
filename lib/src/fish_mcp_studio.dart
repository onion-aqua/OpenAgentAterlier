import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import 'fish_mcp_protocol.dart';

const fishMcpStudioTools = <String>[
  'studio_help',
  'studio_create_project',
  'studio_update_project',
  'studio_project',
  'studio_write_blocks',
  'studio_generate',
];

/// Studio is a separate MCP workflow, with a declared project backend rather
/// than an undeclared model argument on text_to_speech. Projects belong only to
/// this authenticated connection, so reconnecting cannot reuse another team.
class FishMcpStudioSession {
  FishMcpStudioSession({
    required this.client,
    required this.ensureCurrent,
    this.readBlocksAvailable = false,
    this.maximumReadAttempts = 10,
    this.readInterval = const Duration(seconds: 2),
  }) : assert(maximumReadAttempts > 0);

  final McpClient client;
  final void Function() ensureCurrent;
  final bool readBlocksAvailable;
  final int maximumReadAttempts;
  final Duration readInterval;
  Future<void>? _help;
  final _projects = <String, Future<_StudioProject>>{};

  Future<CallToolResult> generate({
    required String text,
    required String voice,
    required String model,
    required void Function() ensureRequestCurrent,
    required void Function() onSubmitted,
    required void Function(String backend) onConfigured,
    required void Function(Map<String, Object?> summary) onSummary,
  }) async {
    ensureRequestCurrent();
    if (voice.trim().isEmpty) {
      throw FishMcpException(
        stage: 'studio_preflight',
        code: 'studio_voice_required',
        message: 'Studio MCP 指定模型时请填写普通音色 ID；ASMR 可以沿用普通音色。',
      );
    }
    await (_help ??= _readHelp());
    ensureRequestCurrent();
    final key = jsonEncode([model, voice]);
    final reused = _projects.containsKey(key);
    final projectFuture = _projects.putIfAbsent(
      key,
      () => _createProject(voice: voice, model: model, onSummary: onSummary),
    );
    late final _StudioProject project;
    try {
      project = await projectFuture;
    } on Object {
      if (identical(_projects[key], projectFuture)) _projects.remove(key);
      rethrow;
    }
    ensureRequestCurrent();
    if (reused) await _verifyProject(project.id, model, onSummary: onSummary);
    ensureRequestCurrent();
    onConfigured(project.backend);
    onSummary({'studio_project_reused': reused});
    final written = _object(
      await _call('studio_write_blocks', {
        'project_id': project.id,
        'ops': [
          {'append_to': project.chapter, 'text': text, 'voice': voice},
        ],
      }),
      'studio_write_blocks',
    );
    ensureRequestCurrent();
    final results = written['results'];
    final entry = results is List && results.length == 1
        ? results.single
        : null;
    final block = entry is Map ? _nonempty(entry['anchor']) : null;
    if (block == null || (entry is Map && entry['error'] != null)) {
      throw _invalid('studio_write_blocks', 'Studio 没有返回本次唯一文本块的 anchor。');
    }
    final arguments = <String, dynamic>{
      'project_id': project.id,
      'blocks': [block],
    };
    final quote = _object(
      await _call('studio_generate', {...arguments, 'dry_run': true}),
      'studio_quote',
    );
    ensureRequestCurrent();
    final estimate = quote['estimated_credits'];
    final count = quote['blocks_to_generate'];
    final cached = quote['cached'];
    final balance = quote['balance'];
    if (estimate is! num ||
        !estimate.isFinite ||
        estimate < 0 ||
        count is! int ||
        cached is! int ||
        count < 0 ||
        cached < 0 ||
        count + cached != 1 ||
        (cached == 1 && estimate != 0)) {
      throw _invalid('studio_quote', 'Studio 费用预估无效或包含其他文本块，已停止生成。');
    }
    if (balance is num && (!balance.isFinite || balance < estimate)) {
      throw FishMcpException(
        stage: 'studio_quote',
        code: 'insufficient_credits',
        message: 'Studio 套餐积分不足以支付本次预估费用，未提交生成。',
      );
    }
    onSummary({
      'estimated_credits': estimate,
      'blocks_to_generate': count,
      'cached': cached,
    });
    // Only this call can generate audio. Never retry it or change providers if
    // its outcome is unknown; project edits and quotes do not count as speech.
    final result = await _call(
      'studio_generate',
      arguments,
      generation: true,
      onSubmitted: onSubmitted,
    );
    ensureRequestCurrent();
    var targetConfirmed = false;
    void summarizeResult(Map<String, Object?> summary) {
      if (summary['studio_result_target_matched'] == true ||
          summary['studio_read_target_matched'] == true) {
        targetConfirmed = true;
      }
      onSummary(summary);
    }

    var completed = _completedResult(
      result,
      project: project,
      block: block,
      onSummary: summarizeResult,
    );
    if (completed != null) return completed;
    // A pending result is not a reason to submit studio_generate again (not
    // even with dry_run). Only the discovered read tool may recover this block.
    onSummary({'studio_read_blocks_available': readBlocksAvailable});
    if (readBlocksAvailable) {
      final readTimer = Stopwatch()..start();
      for (var attempt = 1; attempt <= maximumReadAttempts; attempt++) {
        ensureCurrent();
        ensureRequestCurrent();
        if (attempt > 1 && readInterval > Duration.zero) {
          await Future<void>.delayed(readInterval);
        }
        ensureCurrent();
        ensureRequestCurrent();
        final remaining = const Duration(seconds: 45) - readTimer.elapsed;
        if (remaining <= Duration.zero) break;
        onSummary({'studio_read_attempts': attempt});
        late final CallToolResult observed;
        try {
          observed = await _call(
            'studio_read_blocks',
            {'project_id': project.id, 'chapter': project.chapter},
            timeout: remaining < const Duration(seconds: 30)
                ? remaining
                : const Duration(seconds: 30),
          );
        } on Object catch (cause) {
          throw FishMcpException.fromCause(
            cause,
            stage: 'studio_read_blocks',
            generationSubmitted: true,
            outcomeUnknown: true,
          );
        }
        ensureRequestCurrent();
        completed = _completedResult(
          observed,
          project: project,
          block: block,
          onSummary: summarizeResult,
          readback: true,
        );
        if (completed != null) return completed;
      }
    }
    throw FishMcpException(
      stage: 'studio_result',
      code: targetConfirmed
          ? 'studio_not_completed'
          : 'studio_identity_unconfirmed',
      message: !targetConfirmed
          ? 'Studio 尚未确认音频属于本次文本块${readBlocksAvailable ? '，只读查询期限已结束' : '，且未发现兼容的只读查询工具'}；未播放未确认的音频，未重新生成或回退。'
          : readBlocksAvailable
          ? '本次文本块在只读查询期限内尚未返回可用音频；已保留脱敏状态，未重新生成或回退。'
          : 'Studio 尚未返回本次文本块的可用音频，且未发现兼容的只读查询工具；已保留脱敏状态，未重新生成或回退。',
      outcomeUnknown: true,
      generationSubmitted: true,
    );
  }

  static const _completedStatuses = {
    'done',
    'completed',
    'finished',
    'success',
    'succeeded',
  };
  static const _failedStatuses = {
    'failed',
    'error',
    'cancelled',
    'canceled',
    'rejected',
    'aborted',
  };
  static const _waitingStatuses = {
    'pending',
    'queued',
    'running',
    'processing',
    'generating',
    'submitted',
    'in_progress',
  };

  /// Completion must identify the exact fresh block, including direct results:
  /// project/chapter audio and a single unlabelled result may contain old audio.
  static CallToolResult? _completedResult(
    CallToolResult result, {
    required _StudioProject project,
    required String block,
    required void Function(Map<String, Object?> summary) onSummary,
    bool readback = false,
  }) {
    final data = _optionalObject(result);
    final prefix = readback ? 'studio_read' : 'studio_result';
    onSummary({
      '${prefix}_keys': data == null ? <String>[] : _safeKeys(data),
      '${prefix}_status': _statusLabel(data?['status']),
      '${prefix}_content_types': result.content
          .map((item) => item.type)
          .toList(),
    });
    if (data == null) {
      final audio = result.content.whereType<AudioContent>().toList();
      if (!readback && audio.length == 1) {
        onSummary({'${prefix}_target_matched': false});
        return null;
      }
      throw _invalid('studio_result', 'Studio 未返回可识别的文本块结果。', submitted: true);
    }
    final envelopes = <Map>[data];
    void unwrap(Map parent, int depth) {
      if (depth >= 6) return;
      for (final key in const ['result', 'data', 'structuredContent']) {
        final child = parent[key];
        if (child is Map) {
          envelopes.add(child);
          unwrap(child, depth + 1);
        }
      }
    }

    unwrap(data, 0);
    var waiting = false;
    bool staleFlag(Map value, String key) {
      if (!value.containsKey(key)) return false;
      final flag = value[key];
      if (flag is bool) return flag;
      if (flag is num &&
          flag.isFinite &&
          flag >= 0 &&
          flag == flag.roundToDouble()) {
        if (key == 'dirty' || flag <= 1) return flag > 0;
      }
      throw _invalid(
        'studio_result',
        'Studio $key 状态标志格式无效，未播放可能过期的音频。',
        submitted: true,
      );
    }

    void check(Map value) {
      if (value.containsKey('project_id') &&
          value['project_id'] != project.id) {
        throw _invalid('studio_result', 'Studio 返回了其他项目的结果。', submitted: true);
      }
      if (value.containsKey('chapter_anchor') &&
          value['chapter_anchor'] != project.chapter) {
        throw _invalid('studio_result', 'Studio 返回了其他章节的结果。', submitted: true);
      }
      final status = _nonempty(value['status'])?.toLowerCase();
      if (value['error'] != null ||
          value['isError'] == true ||
          value['success'] == false ||
          _failedStatuses.contains(status)) {
        throw FishMcpException(
          stage: 'studio_result',
          code: 'studio_generation_failed',
          message:
              'Studio 返回本次生成失败或取消（状态：${_statusLabel(value['status'])}）；未重新生成或回退。',
          generationSubmitted: true,
        );
      }
      if ((value.containsKey('status') &&
              !_completedStatuses.contains(status)) ||
          staleFlag(value, 'changed') ||
          staleFlag(value, 'dirty')) {
        waiting = true;
      }
    }

    for (final envelope in envelopes) {
      check(envelope);
    }
    final collections = <List>[];
    for (final envelope in envelopes) {
      for (final key in const ['results', 'blocks']) {
        if (!envelope.containsKey(key)) continue;
        final entries = envelope[key];
        if (entries is! List) {
          throw _invalid('studio_result', 'Studio 文本块列表格式无效。', submitted: true);
        }
        collections.add(entries);
      }
    }
    if (collections.length > 1) {
      throw _invalid(
        'studio_result',
        'Studio 返回了多个有歧义的文本块列表。',
        submitted: true,
      );
    }
    final entries = collections.isEmpty ? <Object?>[] : collections.single;
    onSummary({'${prefix}_block_count': entries.length});
    final matching = entries
        .whereType<Map>()
        .where((entry) => entry['anchor'] == block)
        .toList();
    Map? output;
    if (matching.length > 1) {
      throw _invalid('studio_result', 'Studio 返回了重复的目标文本块。', submitted: true);
    } else if (matching.length == 1) {
      output = matching.single;
    } else if (!readback && entries.length == 1 && entries.single is Map) {
      final single = entries.single as Map;
      if (single.containsKey('anchor')) {
        throw _invalid(
          'studio_result',
          'Studio 返回的文本块与本次请求不符。',
          submitted: true,
        );
      }
      // Missing identity does not excuse an explicit generation error or a
      // malformed stale flag in the single requested operation's response.
      check(single);
      // A sole result may still be a chapter render; a readback must identify
      // the requested anchor before this audio can be accepted.
    } else if (entries.isEmpty && collections.isEmpty) {
      final candidates = envelopes
          .where((entry) => entry['anchor'] == block)
          .toList();
      if (candidates.length == 1) output = candidates.single;
    }
    onSummary({'${prefix}_target_matched': output != null});
    if (output == null) return null;
    final layers = <Map>[
      output,
      if (output['data'] is Map) output['data'] as Map,
    ];
    onSummary({
      '${prefix}_block_keys': _safeKeys(output),
      '${prefix}_block_status': _statusLabel(output['status']),
      '${prefix}_block_data_status': _statusLabel(layers.last['status']),
      '${prefix}_block_changed': layers.any(
        (layer) => staleFlag(layer, 'changed') || staleFlag(layer, 'dirty'),
      ),
      '${prefix}_target_matched': output['anchor'] == block,
    });
    for (final layer in layers) {
      check(layer);
      if (layer.containsKey('anchor') && layer['anchor'] != block) {
        throw _invalid('studio_result', 'Studio 返回的文本块标识冲突。', submitted: true);
      }
    }
    final addresses = <String>{
      for (final layer in layers)
        if (_nonempty(layer['audio_url']) case final String address) address,
    };
    onSummary({'${prefix}_has_audio': addresses.isNotEmpty});
    if (addresses.length > 1) {
      throw _invalid('studio_result', 'Studio 目标文本块存在冲突音频地址。', submitted: true);
    }
    if (waiting || addresses.isEmpty) return null;
    // Do not pass raw content or other blocks to the generic audio parser:
    // a stale root URL/Markdown link must not override the checked output.
    final metadata = <String, dynamic>{};
    for (final layer in [...envelopes, ...layers]) {
      for (final key in const [
        'actual_model',
        'used_model',
        'model',
        'model_id',
        'modelId',
        'model_name',
        'modelName',
      ]) {
        if (layer[key] is String) metadata[key] = layer[key];
      }
      final sourceMetadata = layer['metadata'];
      if (sourceMetadata is Map) {
        for (final key in const [
          'actual_model',
          'used_model',
          'model',
          'model_id',
          'modelId',
          'model_name',
          'modelName',
        ]) {
          if (sourceMetadata[key] is String) {
            metadata[key] = sourceMetadata[key];
          }
        }
      }
    }
    // Duration evidence belongs to the selected block, never a project or
    // chapter envelope whose duration can include previous segments.
    for (final key in const ['duration_s', 'duration_ms']) {
      final values = <num>{};
      for (final layer in layers) {
        final sourceMetadata = layer['metadata'];
        for (final source in [
          layer,
          if (sourceMetadata is Map) sourceMetadata,
        ]) {
          if (!source.containsKey(key)) continue;
          final value = source[key];
          if (value is! num || !value.isFinite || value < 0) {
            throw _invalid(
              'studio_result',
              'Studio 目标文本块的 $key 元数据无效。',
              submitted: true,
            );
          }
          values.add(value);
        }
      }
      if (values.length > 1) {
        throw _invalid(
          'studio_result',
          'Studio 目标文本块存在冲突的 $key 元数据。',
          submitted: true,
        );
      }
      if (values.isNotEmpty) {
        metadata[key] = values.single;
        onSummary({'${prefix}_target_$key': values.single});
      }
    }
    final credits = data['credits'];
    if (credits is num && credits.isFinite) onSummary({'credits': credits});
    return CallToolResult(
      content: const [],
      structuredContent: {
        'status': 'done',
        'results': [
          {'anchor': block, 'audio_url': addresses.single, ...metadata},
        ],
      },
    );
  }

  static List<String> _safeKeys(Map value) => value.keys.take(32).map((key) {
    final text = key.toString();
    return RegExp(r'^[a-zA-Z_][a-zA-Z_0-9]{0,63}$').hasMatch(text)
        ? text
        : '<unrecognized>';
  }).toList();

  static String _statusLabel(Object? value) {
    if (value == null) return 'absent';
    final status = _nonempty(value)?.toLowerCase();
    return {
          ..._completedStatuses,
          ..._failedStatuses,
          ..._waitingStatuses,
        }.contains(status)
        ? status!
        : '<unrecognized>';
  }

  Future<void> _readHelp() async {
    try {
      await _call('studio_help', const {});
    } on Object {
      _help = null;
      rethrow;
    }
  }

  Future<_StudioProject> _createProject({
    required String voice,
    required String model,
    required void Function(Map<String, Object?> summary) onSummary,
  }) async {
    final created = _object(
      await _call('studio_create_project', {
        'name': 'AgentAtelier ${fishMcpModelDiagnosticLabel(model)}',
        'roster': [
          {'name': 'AgentAtelier', 'voice_id': voice},
        ],
        'default_voice_id': voice,
        'chapters': <Object>[],
      }),
      'studio_create_project',
    );
    final id = _nonempty(created['project_id']);
    final chapters = created['chapters'];
    final first = chapters is List && chapters.isNotEmpty
        ? chapters.first
        : null;
    final chapter = first is Map ? _nonempty(first['anchor']) : null;
    if (id == null || chapter == null) {
      throw _invalid(
        'studio_create_project',
        'Studio 项目响应缺少 project_id 或章节 anchor。',
      );
    }
    await _call('studio_update_project', {
      'project_id': id,
      'default_backend': model,
    });
    await _setSceneOff(id);
    await _verifyProject(
      id,
      model,
      onSummary: onSummary,
      sceneAcknowledged: true,
    );
    return _StudioProject(id, chapter, model);
  }

  Future<void> _verifyProject(
    String id,
    String model, {
    required void Function(Map<String, Object?> summary) onSummary,
    bool sceneAcknowledged = false,
  }) async {
    final confirmed = _object(
      await _call('studio_project', {'project_id': id}),
      'studio_project',
    );
    final fields = _configurationFields(confirmed);
    final backends = fields['default_backend']!;
    final scenes = fields['scene_preset']!;
    final projectIds = fields['project_id']!;
    onSummary({
      'studio_project_response_keys': confirmed.keys.take(32).toList(),
      'studio_backend_readback': _describeFields(backends),
      'studio_scene_readback': _describeFields(scenes),
    });
    if (projectIds.any((entry) => entry.value != id)) {
      throw FishMcpException(
        stage: 'studio_project',
        code: 'studio_project_mismatch',
        message: 'Studio 读回的项目标识与请求不符，已停止生成。',
      );
    }
    if (backends.isEmpty ||
        backends.any((entry) => entry.value != model) ||
        scenes.any((entry) => entry.value != 'off')) {
      throw FishMcpException(
        stage: 'studio_project',
        code: 'studio_backend_not_confirmed',
        message:
            'Studio 配置核对失败：请求 default_backend=${fishMcpModelDiagnosticLabel(model)}，'
            '读回 ${_describeFields(backends)}；请求 scene_preset=off，读回 ${_describeFields(scenes)}。已停止生成。',
      );
    }
    // studio_project is a summary: the user's live response reports the
    // backend but omits scene settings. A successful explicit scene update is
    // acknowledged configuration, not evidence that a missing field means off.
    if (scenes.isEmpty && !sceneAcknowledged) await _setSceneOff(id);
    onSummary({
      'studio_scene_status': scenes.isEmpty
          ? 'accepted_unreported'
          : 'confirmed',
    });
  }

  Future<void> _setSceneOff(String id) async {
    final result = await _call('studio_update_project', {
      'project_id': id,
      'scene_preset': 'off',
    });
    final updated = _optionalObject(result);
    if (updated == null) return;
    if (updated['error'] != null) {
      throw _invalid('studio_update_project', 'Studio 场景设置返回了错误，已停止后续操作。');
    }
    final scenes = _configurationFields(updated)['scene_preset']!;
    if (scenes.any((entry) => entry.value != 'off')) {
      throw FishMcpException(
        stage: 'studio_update_project',
        code: 'studio_scene_not_accepted',
        message: 'Studio 场景关闭请求返回了冲突值：${_describeFields(scenes)}。已停止生成。',
      );
    }
  }

  static Map<String, List<({String path, Object? value})>> _configurationFields(
    Map value,
  ) {
    final fields = <String, List<({String path, Object? value})>>{
      'default_backend': [],
      'scene_preset': [],
      'project_id': [],
    };
    void read(Map value, String path, [int depth = 0]) {
      if (depth > 6) return;
      for (final field in fields.keys) {
        if (value.containsKey(field)) {
          fields[field]!.add((path: '$path.$field', value: value[field]));
        }
      }
      // Studio's stored scene configuration is scene.preset; scene_preset is
      // the MCP update argument / older flattened response representation.
      final scene = value['scene'];
      if (scene is Map && scene.containsKey('preset')) {
        fields['scene_preset']!.add((
          path: '$path.scene.preset',
          value: scene['preset'],
        ));
      } else if (value.containsKey('scene')) {
        fields['scene_preset']!.add((
          path: '$path.scene',
          value: scene is Map
              ? scene
              : {'invalid_type': scene.runtimeType.toString()},
        ));
      }
      // Read only project/configuration envelopes, never roster, chapters,
      // request echoes, prose, or arbitrary recursively nested user content.
      for (final key in const ['project', 'settings', 'data', 'result']) {
        final child = value[key];
        if (child is Map) read(child, '$path.$key', depth + 1);
      }
    }

    read(value, r'$');
    return fields;
  }

  static String _describeFields(List<({String path, Object? value})> values) =>
      values.isEmpty
      ? '字段缺失'
      : values
            .map((entry) {
              final value = entry.value;
              final label = value is String
                  ? fishMcpModelDiagnosticLabel(value)
                  : value == null
                  ? 'null'
                  : '<${value.runtimeType}>';
              return '${entry.path}=$label';
            })
            .join('；');

  Future<CallToolResult> _call(
    String name,
    Map<String, dynamic> arguments, {
    bool generation = false,
    void Function()? onSubmitted,
    Duration? timeout,
  }) async {
    ensureCurrent();
    try {
      if (generation) onSubmitted?.call();
      final result = await client.callTool(
        CallToolRequest(name: name, arguments: arguments),
        options: RequestOptions(
          timeout:
              timeout ??
              (generation
                  ? const Duration(seconds: 90)
                  : const Duration(seconds: 30)),
        ),
      );
      ensureCurrent();
      if (result.isError) {
        final error = FishMcpException.fromToolResult(result, stage: name);
        throw FishMcpException(
          stage: name,
          code: error.code,
          status: error.status,
          message: error.message,
          requestId: error.requestId,
          outcomeUnknown: error.outcomeUnknown,
          generationSubmitted: generation,
        );
      }
      return result;
    } on Object catch (cause) {
      throw FishMcpException.fromCause(
        cause,
        stage: name,
        generationSubmitted: generation,
        outcomeUnknown: generation,
      );
    }
  }

  static Map<String, dynamic> _object(
    CallToolResult result,
    String stage, {
    bool submitted = false,
  }) {
    final value = _optionalObject(result);
    if (value == null || value['error'] != null) {
      throw _invalid(stage, 'Studio 返回的结构化数据无效，已停止后续操作。', submitted: submitted);
    }
    return value;
  }

  static Map<String, dynamic>? _optionalObject(CallToolResult result) {
    Object? value = result.hasStructuredContent
        ? result.structuredContentJson?.toJson()
        : null;
    if (value is! Map) {
      for (final block in result.content.whereType<TextContent>()) {
        try {
          final decoded = jsonDecode(block.text);
          if (decoded is Map) {
            value = decoded;
            break;
          }
        } on FormatException {
          // Instructions and prose do not define a project or generation.
        }
      }
    }
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  static String? _nonempty(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static FishMcpException _invalid(
    String stage,
    String message, {
    bool submitted = false,
  }) => FishMcpException(
    stage: stage,
    code: 'invalid_studio_response',
    message: message,
    generationSubmitted: submitted,
    outcomeUnknown: submitted,
  );
}

class _StudioProject {
  const _StudioProject(this.id, this.chapter, this.backend);

  final String id;
  final String chapter;
  final String backend;
}
