import 'dart:convert';
import 'dart:typed_data';

import 'package:mcp_dart/mcp_dart.dart';

/// A diagnostic which keeps the failure stage distinct from its transport.
///
/// [outcomeUnknown] means a request might have reached the service. It is not
/// permission to retry a potentially billable operation.
class FishMcpException implements Exception {
  FishMcpException({
    required this.stage,
    required String message,
    String? code,
    this.status,
    String? requestId,
    this.outcomeUnknown = false,
    this.generationSubmitted = false,
  }) : message = redactFishMcpText(message),
       code = code == null ? null : redactFishMcpText(code),
       requestId = requestId == null ? null : redactFishMcpText(requestId);

  final String stage;
  final String? code;
  final int? status;
  final String message;
  final String? requestId;
  final bool outcomeUnknown;

  /// Once tools/call was submitted, failure must not trigger another provider.
  final bool generationSubmitted;

  bool get allowsRestFallback =>
      !generationSubmitted &&
      !outcomeUnknown &&
      const {'preflight', 'parameters', 'input_schema'}.contains(stage);

  FishMcpException withGenerationSubmitted() => generationSubmitted
      ? this
      : FishMcpException(
          stage: stage,
          message: message,
          code: code,
          status: status,
          requestId: requestId,
          outcomeUnknown: outcomeUnknown,
          generationSubmitted: true,
        );

  factory FishMcpException.fromToolResult(
    CallToolResult result, {
    String stage = 'tool_call',
  }) {
    final values = <Object?>[
      if (result.hasStructuredContent) result.structuredContentJson?.toJson(),
      result.extra,
      result.meta,
      for (final block in result.content)
        if (block is TextContent) _decodeJsonOrText(block.text),
    ];
    final details = _FishMcpErrorDetails();
    for (final value in values) {
      details.read(value);
    }
    return FishMcpException(
      stage: stage,
      message: details.message ?? 'Fish Audio MCP 工具执行失败，服务未提供错误说明。',
      code: details.code,
      status: details.status,
      requestId: details.requestId,
      outcomeUnknown: details.outcomeUnknown ?? false,
      generationSubmitted: true,
    );
  }

  factory FishMcpException.fromCause(
    Object cause, {
    required String stage,
    int? status,
    String? requestId,
    bool outcomeUnknown = false,
    bool generationSubmitted = false,
  }) {
    if (cause is FishMcpException) {
      return generationSubmitted ? cause.withGenerationSubmitted() : cause;
    }
    final details = _FishMcpErrorDetails();
    if (cause is McpError) {
      details.read(cause.data);
    }
    final rawMessage = cause is McpError ? cause.message : cause.toString();
    final httpMatch = RegExp(r'\bHTTP\s+(\d{3})\b').firstMatch(rawMessage);
    final bodyStart = rawMessage.indexOf('): ');
    if (bodyStart >= 0) {
      details.read(_decodeJsonOrText(rawMessage.substring(bodyStart + 3)));
    }
    details.read(_decodeJsonOrText(rawMessage));
    return FishMcpException(
      stage: stage,
      message: details.message ?? rawMessage,
      code: details.code ?? (cause is McpError ? '${cause.code}' : null),
      status:
          status ?? details.status ?? int.tryParse(httpMatch?.group(1) ?? ''),
      requestId: requestId ?? details.requestId,
      outcomeUnknown: details.outcomeUnknown ?? outcomeUnknown,
      generationSubmitted: generationSubmitted,
    );
  }

  Map<String, Object?> toJson() => {
    'stage': stage,
    if (code != null) 'code': code,
    if (status != null) 'status': status,
    'message': message,
    if (requestId != null) 'request_id': requestId,
    'outcome_unknown': outcomeUnknown,
    if (generationSubmitted) 'generation_submitted': true,
  };

  @override
  String toString() {
    final fields = [
      'stage=$stage',
      if (code != null) 'code=$code',
      if (status != null) 'HTTP=$status',
      if (requestId != null) 'request_id=$requestId',
      if (outcomeUnknown) 'outcome_unknown=true，勿自动重试',
      if (generationSubmitted) 'generation_submitted=true，不自动回退',
    ].join(', ');
    return 'FishMcpException($fields): $message';
  }
}

Object? _decodeJsonOrText(String value) {
  try {
    return jsonDecode(value);
  } on FormatException {
    return value;
  }
}

class _FishMcpErrorDetails {
  String? message;
  String? code;
  int? status;
  String? requestId;
  bool? outcomeUnknown;

  void read(Object? value, [int depth = 0]) {
    if (depth > 10 || value == null) return;
    if (value is Map) {
      // The nested service error is more specific than its outer wrapper.
      for (final key in const ['error', 'detail', 'details']) {
        if (value[key] is Map || value[key] is List) {
          read(value[key], depth + 1);
        }
      }
      message ??= _text(value['message']) ?? _text(value['error_description']);
      code ??= _text(value['code']) ?? _text(value['error_code']);
      if (value['error'] is String) code ??= _text(value['error']);
      message ??= _text(value['detail']) ?? _text(value['error']);
      for (final key in const [
        'status',
        'status_code',
        'statusCode',
        'http_status',
        'httpStatus',
      ]) {
        status ??= int.tryParse('${value[key]}');
      }
      for (final key in const [
        'request_id',
        'requestId',
        'request-id',
        'x-request-id',
        'trace_id',
        'traceId',
      ]) {
        requestId ??= _text(value[key]);
      }
      for (final entry in value.entries) {
        final key = '${entry.key}'.toLowerCase().replaceAll(
          RegExp('[^a-z]'),
          '',
        );
        if (key == 'requestid' || key == 'xrequestid' || key == 'traceid') {
          requestId ??= _text(entry.value);
        }
      }
      outcomeUnknown ??= value['outcome_unknown'] is bool
          ? value['outcome_unknown'] as bool
          : null;
      for (final key in const ['data', '_meta', 'meta', 'headers', 'result']) {
        read(value[key], depth + 1);
      }
    } else if (value is List) {
      for (final child in value) {
        read(child, depth + 1);
      }
    } else if (value is String && value.trim().isNotEmpty) {
      final decoded = _decodeJsonOrText(value);
      if (decoded is! String) {
        read(decoded, depth + 1);
      } else {
        message ??= decoded;
        requestId ??= RegExp(
          r'(?:request[_ -]?id|trace[_ -]?id)\s*[:=]\s*([A-Za-z0-9_.:-]+)',
          caseSensitive: false,
        ).firstMatch(decoded)?.group(1);
      }
    }
  }

  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty
      ? value.trim()
      : value is num
      ? '$value'
      : null;
}

bool _isSensitiveKey(String key) {
  final normalized = key.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
  return normalized.contains('authorization') ||
      normalized.contains('accesstoken') ||
      normalized.contains('refreshtoken') ||
      normalized.contains('apikey') ||
      normalized.contains('secret') ||
      normalized.contains('cookie') ||
      normalized.contains('codeverifier') ||
      normalized.contains('authorizationcode') ||
      normalized.contains('pkce') ||
      normalized == 'token';
}

/// Redacts secrets recursively without erasing an ordinary service error code.
Object? redactFishMcpValue(Object? value) {
  if (value is Map) {
    return {
      for (final entry in value.entries)
        '${entry.key}': _isSensitiveKey('${entry.key}')
            ? '[REDACTED]'
            : redactFishMcpValue(entry.value),
    };
  }
  if (value is Iterable) return value.map(redactFishMcpValue).toList();
  if (value is String) return redactFishMcpText(value);
  return value;
}

/// Safe for error UI and logs. URL queries may contain signed credentials.
String redactFishMcpText(String value) {
  var result = value.replaceAll(
    RegExp(r'\bBearer\s+[^\s,;"\x27]+', caseSensitive: false),
    'Bearer [REDACTED]',
  );
  result = result.replaceAll(
    RegExp(r'\bsk-[A-Za-z0-9_-]{8,}\b'),
    'sk-[REDACTED]',
  );
  result = result.replaceAllMapped(
    RegExp(
      r'''(["']?(?:access[_-]?token|refresh[_-]?token|api[_-]?key|authorization|cookie|set-cookie|client[_-]?secret|pairing[_-]?secret|code[_-]?verifier|authorization[_-]?code)["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}]+)''',
      caseSensitive: false,
    ),
    (match) => '${match[1]}[REDACTED]',
  );
  return result.replaceAllMapped(
    RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false),
    (match) {
      final raw = match[0]!;
      final uri = Uri.tryParse(raw);
      if (uri == null || (uri.query.isEmpty && uri.userInfo.isEmpty)) {
        return raw;
      }
      return uri.replace(userInfo: '', query: '', fragment: '').toString();
    },
  );
}

/// A bounded diagnostic label only; this never changes generation arguments.
String fishMcpModelDiagnosticLabel(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.length > 96 ||
      trimmed.contains('://') ||
      RegExp(r'\bBearer\b', caseSensitive: false).hasMatch(trimmed) ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._:/+\-]*$').hasMatch(trimmed) ||
      redactFishMcpText(trimmed) != trimmed) {
    return '[REDACTED]';
  }
  return trimmed;
}

/// Reads explicit response metadata, never prose, voice names, or request echoes.
/// A missing model field does not establish which model generated the audio.
String? fishMcpReportedModel(CallToolResult result) {
  const actualModelFields = ['actual_model', 'used_model'];
  const modelFields = [
    'model',
    'model_id',
    'modelId',
    'model_name',
    'modelName',
  ];
  const containers = [
    'generation',
    'result',
    'results',
    'data',
    'metadata',
    '_meta',
    'meta',
    'output',
    'response',
  ];
  String? read(Object? value, List<String> fields, [int depth = 0]) {
    if (depth > 10) return null;
    if (value is Map) {
      for (final field in fields) {
        final raw = value[field];
        if (raw is! String) continue;
        final name = fishMcpModelDiagnosticLabel(raw);
        if (name.isNotEmpty && name != '[REDACTED]') return name;
      }
      for (final field in containers) {
        final name = read(value[field], fields, depth + 1);
        if (name != null) return name;
      }
    } else if (value is List) {
      for (final child in value.take(32)) {
        final name = read(child, fields, depth + 1);
        if (name != null) return name;
      }
    }
    return null;
  }

  final sources = <Object?>[
    result.hasStructuredContent ? result.structuredContentJson?.toJson() : null,
    result.meta,
    result.extra,
  ];
  for (final block in result.content.whereType<TextContent>()) {
    final text = block.text.trim();
    if (text.length > 1024 * 1024 ||
        (!text.startsWith('{') && !text.startsWith('['))) {
      continue;
    }
    sources.add(_decodeJsonOrText(text));
  }
  // An outer wrapper can echo the requested model while generation metadata
  // reports the model used. Prefer explicit actual/used fields across sources.
  for (final fields in [actualModelFields, modelFields]) {
    for (final source in sources) {
      final name = read(source, fields);
      if (name != null) return name;
    }
  }
  return null;
}

class FishMcpToolDefinition {
  const FishMcpToolDefinition({
    required this.name,
    this.description,
    required this.inputSchema,
  });

  final String name;
  final String? description;
  final Map<String, dynamic> inputSchema;
}

const _textFields = ['text', 'input_text', 'content'];

/// Selects a generation tool by its explicit name.
///
/// A description that merely mentions TTS, or a voice/credit search tool, is
/// insufficient. The ordering is deterministic when the service offers several
/// variants; the canonical text_to_speech wins.
FishMcpToolDefinition? selectFishMcpTtsTool(
  Iterable<FishMcpToolDefinition> tools,
) {
  final scored = <({FishMcpToolDefinition tool, int score})>[];
  for (final tool in tools) {
    final normalized = tool.name.toLowerCase().replaceAll(
      RegExp('[^a-z0-9]+'),
      '_',
    );
    final tokens = normalized.split('_');
    if (tokens.any(
      const {
        'get',
        'list',
        'search',
        'find',
        'query',
        'check',
        'estimate',
        'credit',
        'credits',
        'balance',
        'billing',
        'usage',
        'quota',
        'transcribe',
        'transcription',
        'recognize',
        'delete',
      }.contains,
    )) {
      continue;
    }
    final candidates = const {
      'text_to_speech': 100,
      'synthesize_speech': 90,
      'speech_synthesis': 90,
      'generate_speech': 85,
      'generate_tts': 80,
      'tts_generate': 80,
      'synthesize_audio': 75,
      'tts': 70,
    };
    var score = 0;
    for (final entry in candidates.entries) {
      if (normalized == entry.key || normalized.endsWith('_${entry.key}')) {
        if (entry.value > score) score = entry.value;
      }
    }
    if (score == 0) continue;
    scored.add((tool: tool, score: score));
  }
  scored.sort((a, b) {
    final rank = b.score.compareTo(a.score);
    return rank != 0 ? rank : a.tool.name.compareTo(b.tool.name);
  });
  return scored.isEmpty ? null : scored.first.tool;
}

/// Maps declared field aliases without rejecting requests against cached schema.
/// The cloud service validates models and other generation parameters.
Map<String, dynamic> buildFishMcpTtsArguments({
  required FishMcpToolDefinition tool,
  required String text,
  String? voice,
  String? model,
  String? language,
  String? format,
  double? speed,
  void Function(String field, String explanation)? onOmittedOptionalField,
}) {
  final properties = _schemaProperties(tool.inputSchema);
  final arguments = <String, dynamic>{};
  void put(List<String> aliases, Object? value) {
    if (value == null || (value is String && value.trim().isEmpty)) return;
    for (final name in aliases) {
      if (!properties.containsKey(name)) continue;
      arguments[name] = value;
      return;
    }
  }

  final textField =
      _textFields.where(properties.containsKey).firstOrNull ?? 'text';
  arguments[textField] = text;
  if (voice != null && voice.trim().isNotEmpty) {
    final voiceField =
        const [
          'voice',
          'voice_id',
          'speaker',
          'reference_id',
        ].where(properties.containsKey).firstOrNull ??
        'voice_id';
    arguments[voiceField] = voice;
  }
  if (model != null && model.trim().isNotEmpty) {
    final modelField = const [
      'model',
      'model_id',
      'modelId',
    ].where(properties.containsKey).firstOrNull;
    if (modelField != null) {
      arguments[modelField] = model;
    }
  }
  final languageField = const [
    'language',
    'lang',
  ].where(properties.containsKey).firstOrNull;
  var languageValue = language;
  if (languageField != null && language != null && language.trim().isNotEmpty) {
    final schema = properties[languageField];
    final values = schema is Map ? schema['enum'] : null;
    if (values is List && !values.contains(language)) {
      final aliases = _languageAliases(language);
      languageValue = values
          .whereType<String>()
          .where((value) => aliases.contains(value.toLowerCase()))
          .firstOrNull;
      if (languageValue == null &&
          !_schemaRequiredFields(tool.inputSchema).contains(languageField)) {
        onOmittedOptionalField?.call(
          languageField,
          '语言参数与工具枚举不匹配，已省略可选参数并使用服务默认语言。',
        );
      } else {
        // Preserve an unmatched required language for cloud-side validation.
        languageValue ??= language;
      }
    }
  }
  put(const ['language', 'lang'], languageValue);
  put(const ['format', 'output_format'], format);
  put(const ['speed', 'prosody_speed'], speed);
  return Map.unmodifiable(arguments);
}

Set<String> _languageAliases(String language) {
  final normalized = language.toLowerCase().replaceAll('_', '-');
  const groups = [
    {'ja', 'ja-jp', 'jp', 'japanese', '日本語', '日语'},
    {'zh', 'zh-cn', 'zh-hans', 'chinese', 'mandarin', '简体中文', '中文'},
    {'zh-tw', 'zh-hant', 'traditional chinese', '繁體中文', '繁体中文'},
    {'en', 'en-us', 'en-gb', 'english', '英语'},
  ];
  for (final group in groups) {
    if (group.contains(normalized)) return group;
  }
  return {normalized};
}

Set<String> _schemaRequiredFields(Map<String, dynamic> root) {
  final required = <String>{};
  void visit(Object? value, [int depth = 0]) {
    if (value is! Map || depth > 12) return;
    final fields = value['required'];
    if (fields is List) required.addAll(fields.whereType<String>());
    final branches = value['allOf'];
    if (branches is List) {
      for (final branch in branches) {
        visit(branch, depth + 1);
      }
    }
    final ref = value[r'$ref'];
    if (ref is String && ref.startsWith('#/')) {
      Object? target = root;
      for (final part in ref.substring(2).split('/')) {
        target = target is Map
            ? target[part.replaceAll('~1', '/').replaceAll('~0', '~')]
            : null;
      }
      visit(target, depth + 1);
    }
  }

  visit(root);
  return required;
}

/// The adapter and settings must agree on fields declared through local refs.
Map<String, dynamic> fishMcpSchemaProperties(Map<String, dynamic> root) =>
    Map.unmodifiable(_schemaProperties(root));

Set<String> fishMcpSchemaRequiredFields(Map<String, dynamic> root) =>
    Set.unmodifiable(_schemaRequiredFields(root));

Map<String, dynamic> _schemaProperties(Map<String, dynamic> root) {
  final result = <String, dynamic>{};
  void visit(Object? value, [int depth = 0]) {
    if (value is! Map || depth > 12) return;
    final properties = value['properties'];
    if (properties is Map) {
      for (final entry in properties.entries) {
        result['${entry.key}'] = entry.value;
      }
    }
    final ref = value[r'$ref'];
    if (ref is String && ref.startsWith('#/')) {
      Object? target = root;
      for (final part in ref.substring(2).split('/')) {
        target = target is Map
            ? target[part.replaceAll('~1', '/').replaceAll('~0', '~')]
            : null;
      }
      visit(target, depth + 1);
    }
    for (final key in const ['allOf', 'anyOf', 'oneOf']) {
      final branches = value[key];
      if (branches is List) {
        for (final branch in branches) {
          visit(branch, depth + 1);
        }
      }
    }
  }

  visit(root);
  return result;
}

/// Download destinations are opt-in HTTPS domains. Redirects must be validated
/// by the downloader with this same policy before following them.
class FishMcpAudioUrlPolicy {
  const FishMcpAudioUrlPolicy({
    this.allowedDomains = const {'fish.audio'},
    this.additionalHosts = const {},
  });

  final Set<String> allowedDomains;
  final Set<String> additionalHosts;

  Uri validate(Uri uri) {
    final host = uri.host.toLowerCase();
    if (uri.scheme.toLowerCase() != 'https' ||
        host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw FishMcpException(
        stage: 'audio_url',
        code: 'unsafe_audio_url',
        message: 'MCP 音频地址必须为不带用户凭据的 HTTPS 地址。',
      );
    }
    final allowed =
        additionalHosts.any((allowed) => host == allowed.toLowerCase()) ||
        allowedDomains.any((domain) {
          final normalized = domain.toLowerCase();
          return host == normalized || host.endsWith('.$normalized');
        });
    if (!allowed) {
      throw FishMcpException(
        stage: 'audio_url',
        code: 'untrusted_audio_host',
        message: 'MCP 已返回音频链接，但下载域名 $host 尚未受信任；请先核实官方 CDN 域名并显式配置。',
      );
    }
    if (uri.hasPort && uri.port != 443) {
      throw FishMcpException(
        stage: 'audio_url',
        code: 'unsafe_audio_port',
        message: 'MCP 音频地址使用了未允许的 HTTPS 端口。',
      );
    }
    return uri;
  }
}

class FishMcpAudioPayload {
  const FishMcpAudioPayload.bytes(this.bytes, this.mimeType) : uri = null;
  const FishMcpAudioPayload.url(this.uri, this.mimeType) : bytes = null;

  final Uint8List? bytes;
  final Uri? uri;
  final String mimeType;
}

/// Parses a completed tool result without downloading or generating anything.
FishMcpAudioPayload parseFishMcpAudioResult(
  CallToolResult result, {
  FishMcpAudioUrlPolicy policy = const FishMcpAudioUrlPolicy(),
  int maximumInlineBytes = 32 * 1024 * 1024,
}) {
  if (result.isError) throw FishMcpException.fromToolResult(result);
  final parser = _FishMcpAudioParser(policy, maximumInlineBytes);
  for (final content in result.content) {
    FishMcpAudioPayload? audio;
    if (content is AudioContent) {
      audio = parser.inline(content.data, content.mimeType);
    } else if (content is ResourceLink &&
        parser.isAudio(content.mimeType, content.uri)) {
      audio = parser.url(content.uri, content.mimeType);
    } else if (content is EmbeddedResource) {
      final resource = content.resource;
      if (resource is BlobResourceContents &&
          parser.isAudio(resource.mimeType, resource.uri)) {
        audio = parser.inline(
          resource.blob,
          resource.mimeType ?? parser.mimeFor(resource.uri),
        );
      } else if (resource is TextResourceContents) {
        audio = parser.text(resource.text, mimeType: resource.mimeType);
      }
    } else if (content is TextContent) {
      audio = parser.text(content.text);
    }
    if (audio != null) return audio;
  }
  if (result.hasStructuredContent) {
    final audio = parser.json(result.structuredContentJson?.toJson());
    if (audio != null) return audio;
  }
  throw FishMcpException(
    stage: 'audio_result',
    code: 'audio_not_found',
    message:
        'Fish Audio MCP 工具已返回，但结果中没有可识别的音频数据或 HTTPS 音频链接（content 类型：${result.content.map((item) => item.type).join(', ')}）。未自动重试。',
  );
}

class _FishMcpAudioParser {
  _FishMcpAudioParser(this.policy, this.maximumInlineBytes);

  final FishMcpAudioUrlPolicy policy;
  final int maximumInlineBytes;

  String mimeFor(String uri) {
    final path = Uri.tryParse(uri)?.path.toLowerCase() ?? '';
    for (final entry in const {
      '.wav': 'audio/wav',
      '.ogg': 'audio/ogg',
      '.opus': 'audio/ogg',
      '.flac': 'audio/flac',
      '.aac': 'audio/aac',
      '.m4a': 'audio/mp4',
    }.entries) {
      if (path.endsWith(entry.key)) return entry.value;
    }
    return 'audio/mpeg';
  }

  bool isAudio(String? mime, String uri) =>
      mime?.toLowerCase().startsWith('audio/') == true ||
      RegExp(
        r'\.(?:mp3|wav|ogg|opus|flac|aac|m4a)$',
        caseSensitive: false,
      ).hasMatch(Uri.tryParse(uri)?.path ?? '');

  FishMcpAudioPayload inline(String encoded, String mimeType) {
    if (!mimeType.toLowerCase().startsWith('audio/')) {
      throw FishMcpException(
        stage: 'audio_result',
        code: 'invalid_audio_mime',
        message: 'MCP 内嵌音频 MIME 类型无效：$mimeType。',
      );
    }
    if (encoded.length > ((maximumInlineBytes + 2) ~/ 3) * 4 + 16) {
      throw FishMcpException(
        stage: 'audio_result',
        code: 'audio_payload_too_large',
        message: 'MCP 内嵌音频超过允许的大小，未解码或播放。',
      );
    }
    Uint8List bytes;
    try {
      bytes = base64Decode(encoded.replaceAll(RegExp(r'\s'), ''));
    } on FormatException {
      throw FishMcpException(
        stage: 'audio_result',
        code: 'invalid_audio_base64',
        message: 'MCP 返回的内嵌音频不是有效的 Base64 数据。',
      );
    }
    if (bytes.isEmpty || bytes.length > maximumInlineBytes) {
      throw FishMcpException(
        stage: 'audio_result',
        code: 'empty_or_oversized_audio',
        message: 'MCP 返回的内嵌音频为空或超过允许的大小。',
      );
    }
    return FishMcpAudioPayload.bytes(bytes, mimeType);
  }

  FishMcpAudioPayload url(String value, String? mime) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) {
      throw FishMcpException(
        stage: 'audio_url',
        code: 'invalid_audio_url',
        message: 'MCP 返回了无法解析的音频地址。',
      );
    }
    return FishMcpAudioPayload.url(
      policy.validate(uri),
      mime ?? mimeFor(value),
    );
  }

  FishMcpAudioPayload? text(String value, {String? mimeType, int depth = 0}) {
    if (depth > 12) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final decoded = _decodeJsonOrText(trimmed);
    if (decoded is! String) return json(decoded, depth: depth + 1);
    final dataUri = RegExp(
      r'^data:(audio/[\w.+-]+);base64,([\s\S]+)$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (dataUri != null) return inline(dataUri[2]!, dataUri[1]!);
    if (RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(trimmed)) {
      return url(trimmed, mimeType);
    }
    final markdown = RegExp(
      r'!?\[([^\]]*)\]\(<?(https?://[^\s)>]+)>?(?:\s+"[^"]*")?\)',
      caseSensitive: false,
    );
    for (final match in markdown.allMatches(trimmed)) {
      final label = match[1]!;
      final address = match[2]!;
      if (isAudio(mimeType, address) ||
          RegExp(
            r'audio|speech|voice|音频|语音|下载',
            caseSensitive: false,
          ).hasMatch(label)) {
        return url(address, mimeType);
      }
    }
    for (final match in RegExp(
      r'''https?://[^\s<>"')\]]+''',
      caseSensitive: false,
    ).allMatches(trimmed)) {
      final address = match[0]!;
      if (isAudio(mimeType, address)) return url(address, mimeType);
    }
    if (mimeType?.startsWith('audio/') == true) {
      return inline(trimmed, mimeType!);
    }
    return null;
  }

  FishMcpAudioPayload? json(
    Object? value, {
    int depth = 0,
    String? inheritedMime,
  }) {
    if (depth > 12) return null;
    if (value is String) {
      return text(value, mimeType: inheritedMime, depth: depth + 1);
    }
    if (value is List) {
      for (final child in value) {
        final audio = json(
          child,
          depth: depth + 1,
          inheritedMime: inheritedMime,
        );
        if (audio != null) return audio;
      }
    }
    if (value is! Map) return null;
    final rawMime =
        value['mimeType'] ??
        value['mime_type'] ??
        value['content_type'] ??
        inheritedMime;
    final mime = rawMime is String ? rawMime : null;
    for (final key in const ['audio_url', 'audioUrl', 'download_url']) {
      final address = value[key];
      if (address is String && address.isNotEmpty) return url(address, mime);
    }
    for (final key in const ['url', 'uri']) {
      final address = value[key];
      if (address is String && isAudio(mime, address)) {
        return url(address, mime);
      }
    }
    for (final key in const [
      'audio_base64',
      'base64',
      'blob',
      'data',
      'audio',
    ]) {
      final raw = value[key];
      if (raw is! String || raw.isEmpty) continue;
      if (key == 'audio' &&
          RegExp(r'^https?://', caseSensitive: false).hasMatch(raw)) {
        return url(raw, mime);
      }
      if (key == 'audio_base64' || mime?.startsWith('audio/') == true) {
        return inline(raw, mime ?? 'audio/mpeg');
      }
    }
    for (final key in const [
      'result',
      'results',
      'output',
      'audio_data',
      'audio',
      'resource',
      'content',
      'files',
      'assets',
      'attachments',
      'data',
    ]) {
      final audio = json(value[key], depth: depth + 1, inheritedMime: mime);
      if (audio != null) return audio;
    }
    return null;
  }
}
