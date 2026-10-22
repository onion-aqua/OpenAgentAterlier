import 'package:flutter/services.dart';

/// A mapping for a known rig, without a skeleton, atlas or texture.
///
/// Importing a model does not make arbitrary rigs compatible with a template.
/// Playback still checks the actual imported skeleton's animation catalogue.
class SpineControlTemplate {
  const SpineControlTemplate({
    required this.id,
    required this.label,
    required this.sourceBase,
    required this.posture,
  });

  final String id;
  final String label;
  final String sourceBase;
  final String posture;

  String get assetPath => 'assets/data/spine_templates/$id.json';
}

abstract final class SpineControlTemplates {
  static const all = <SpineControlTemplate>[
    SpineControlTemplate(
      id: 'seated_01',
      label: '常服·坐姿',
      sourceBase: 'crf_skn_002_0001_01',
      posture: 'seated',
    ),
    SpineControlTemplate(
      id: 'standing_99',
      label: '常服·站姿',
      sourceBase: 'crf_skn_002_0001_99',
      posture: 'standing',
    ),
    SpineControlTemplate(
      id: 'summer_yellow_01',
      label: '夏日泳装·黄色',
      sourceBase: 'crf_skn_002_0002_01',
      posture: 'seated',
    ),
    SpineControlTemplate(
      id: 'summer_black_01',
      label: '夏日泳装·黑色',
      sourceBase: 'crf_skn_002_0003_01',
      posture: 'seated',
    ),
    SpineControlTemplate(
      id: 'relaxed_shirt_01',
      label: '休闲 T 恤',
      sourceBase: 'crf_skn_002_0004_01',
      posture: 'seated',
    ),
    SpineControlTemplate(
      id: 'crf_skn_002_0005_01',
      label: '夏日泳装·蓝白短裤',
      sourceBase: 'crf_skn_002_0005_01',
      posture: 'seated',
    ),
    SpineControlTemplate(
      id: 'crf_skn_002_0006_01',
      label: '东方旗袍·紫色',
      sourceBase: 'crf_skn_002_0006_01',
      posture: 'seated',
    ),
  ];

  static SpineControlTemplate? byId(String id) =>
      all.where((template) => template.id == id).firstOrNull;

  static SpineControlTemplate? templateForBase(String base) =>
      all.where((template) => template.sourceBase == base).firstOrNull;

  static Future<Uint8List> read(String id, {AssetBundle? bundle}) async {
    final template = byId(id);
    if (template == null) {
      throw FormatException('Unknown Spine control template: $id');
    }
    final bytes = await (bundle ?? rootBundle).load(template.assetPath);
    return Uint8List.fromList(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
  }
}
