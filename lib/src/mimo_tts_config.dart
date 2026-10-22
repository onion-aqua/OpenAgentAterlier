class MimoTtsConfig {
  const MimoTtsConfig({
    this.baseUrl = 'https://api.xiaomimimo.com/v1',
    this.model = cloneModel,
    this.voice = 'mimo_default',
    this.referencePath = '',
    this.referenceName = '',
    this.instructions = '',
    this.asmrInstructions = '近距离轻声耳语，气息柔和，降低音量，语速稍慢。保持原音色，避免突然提高音量。',
  });

  static const cloneModel = 'mimo-v2.5-tts-voiceclone';
  static const presetModel = 'mimo-v2.5-tts';
  static const designModel = 'mimo-v2.5-tts-voicedesign';
  static const models = [cloneModel, presetModel, designModel];
  final String baseUrl;
  final String model;
  final String voice;
  final String referencePath;
  final String referenceName;
  final String instructions;
  final String asmrInstructions;
  bool get isClone => model == cloneModel;
  bool get isDesign => model == designModel;

  String? get validationError {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return '请填写有效的 API 地址，不要在地址中填写密钥或查询参数';
    }
    if (!models.contains(model)) return '请选择 MiMo TTS 模型';
    if (isClone && referencePath.isEmpty) return '请先选择 MP3 或 WAV 参考音频';
    if (isDesign && instructions.trim().isEmpty) return '音色设计模式需要填写音色描述';
    if (model == presetModel && voice.trim().isEmpty) return '请填写预置音色';
    return null;
  }

  Map<String, dynamic> toJson({bool includeLocalReference = true}) => {
    'baseUrl': baseUrl,
    'model': model,
    'voice': voice,
    if (includeLocalReference) 'referencePath': referencePath,
    'referenceName': referenceName,
    'instructions': instructions,
    'asmrInstructions': asmrInstructions,
  };

  factory MimoTtsConfig.fromJson(
    Object? value, {
    bool allowLocalReference = true,
  }) {
    final json = value is Map ? value : const {};
    const defaults = MimoTtsConfig();
    String read(String key, String fallback) =>
        json[key] is String ? json[key] as String : fallback;
    final model = read('model', defaults.model);
    return MimoTtsConfig(
      baseUrl: read('baseUrl', defaults.baseUrl),
      model: models.contains(model) ? model : defaults.model,
      voice: read('voice', defaults.voice),
      referencePath: allowLocalReference ? read('referencePath', '') : '',
      referenceName: read('referenceName', ''),
      instructions: read('instructions', ''),
      asmrInstructions: read('asmrInstructions', defaults.asmrInstructions),
    );
  }
}
