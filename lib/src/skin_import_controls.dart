import 'dart:convert';

import 'spine36_player.dart';

import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:spine_flutter/spine_flutter.dart' hide Color;

import 'app_localization.dart';
import 'app_controller.dart';
import 'character_appearance.dart';
import 'local_skin_store.dart';
import 'local_live2d_store.dart';
import 'local_scene_store.dart';
import 'model_resource_catalog.dart';
import 'model_performance_mapping.dart';
import 'model_mapping_review_page.dart';
import 'protected_character_assets.dart';
import 'runtime_log.dart';
import 'spine_control_templates.dart';
import 'model_package_store.dart';

class SkinImportControls extends StatefulWidget {
  const SkinImportControls({
    super.key,
    required this.appearances,
    required this.language,
    required this.onImported,
    required this.onTextureChanged,
    this.embedded = false,
    this.characterId = 'ryza',
    this.controller,
  });

  final List<CharacterAppearance> appearances;
  final AppLanguage language;
  final ValueChanged<CharacterAppearance> onImported;
  final ValueChanged<CharacterAppearance> onTextureChanged;
  final bool embedded;
  final String characterId;
  final AppController? controller;

  @override
  State<SkinImportControls> createState() => _SkinImportControlsState();
}

class _SkinImportControlsState extends State<SkinImportControls> {
  bool _busy = false;
  String? _error;

  String t(String zh, String en, String ja) => widget.language.text(zh, en, ja);

  Future<Uint8List?> _pick(
    String extension, {
    int maxBytes = maxSkinImportBytes,
  }) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [extension],
    );
    if (result.isEmpty) return null;
    final selected = result.single;
    if (await selected.length() > maxBytes) {
      throw FormatException('Maximum size: ${maxBytes ~/ (1024 * 1024)} MB');
    }
    final bytes = await selected.readAsBytes();
    if (bytes.length > maxBytes) {
      throw FormatException('Maximum size: ${maxBytes ~/ (1024 * 1024)} MB');
    }
    return bytes;
  }

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } on Object catch (error, stack) {
      RuntimeLog.instance.error('SkinImport', error, stack);
      if (mounted) {
        setState(
          () => _error = '${t('导入失败', 'Import failed', '読み込み失敗')}: $error',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importZip() async {
    final kind = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (context) => SimpleDialog(
        title: Text(t('导入资源', 'Import resources', '素材を読み込む')),
        children: [
          for (final entry in {
            'spine': 'Spine · ${t('AI 映射', 'AI mapping', 'AI マッピング')}',
            'live2d': 'Live2D · Cubism model3',
            'package': t('模型与数据 ZIP', 'Model and data ZIP', 'モデルとデータ ZIP'),
            'vrm': 'VRM · ${t('分析模型', 'Analyze model', 'モデル解析')}',
            'scene': t(
              '场景 / 座椅 Spine 包',
              'Scene / seat Spine package',
              '背景・椅子 Spine パック',
            ),
          }.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, entry.key),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(entry.value),
              ),
            ),
        ],
      ),
    );
    if (!mounted || kind == null) return;
    if (kind == 'scene') {
      final bytes = await _pick('zip', maxBytes: 256 * 1024 * 1024);
      if (bytes == null) return;
      final result = await LocalSceneStore.instance.importPackage(bytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                '已导入 ${result.sceneIds.length} 个场景${result.importedSeat ? '和座椅' : ''}',
                'Imported ${result.sceneIds.length} scenes${result.importedSeat ? ' and seat' : ''}',
                '${result.sceneIds.length} 個の背景を読み込みました',
              ),
            ),
          ),
        );
      }
      return;
    }
    DecodedModelPackage? importedPackage;
    var bytes = await _pick(
      kind == 'vrm' ? 'vrm' : 'zip',
      maxBytes: kind == 'package'
          ? ModelPackageStore.maxPackageBytes
          : kind == 'spine'
          ? maxSkinImportBytes
          : 128 * 1024 * 1024,
    );
    if (bytes == null) return;
    if (kind == 'package') {
      if (widget.controller == null) {
        throw const FormatException('恢复模型数据需要从应用模型导入入口进入');
      }
      importedPackage = ModelPackageStore.decodePackage(bytes);
      bytes = importedPackage.modelZip;
    }
    final format = ModelResourceFormat.values.byName(
      importedPackage?.manifest['format'] as String? ?? kind,
    );
    final catalog = await inspectModelResources(bytes, format: format);
    if (!mounted) return;
    final sourceName = catalog.entryFile.split('/').last;
    final sourceBase = sourceName.replaceFirst(RegExp(r'\.[^.]+$'), '');
    final compatibleTemplate =
        format == ModelResourceFormat.spine &&
            !isSpine36(catalog.runtimeVersion)
        ? SpineControlTemplates.templateForBase(sourceBase)
        : null;
    var preserveTemplate = compatibleTemplate != null;
    final mapping = await Navigator.of(context).push<ModelPerformanceMapping>(
      MaterialPageRoute(
        builder: (_) => ModelMappingReviewPage(
          catalog: catalog,
          controller: widget.controller,
          compatibleTemplateLabel: compatibleTemplate?.label,
          onPreserveTemplateChanged: (value) => preserveTemplate = value,
        ),
      ),
    );
    if (mapping == null || !mounted) return;
    final mappingBytes = Uint8List.fromList(
      utf8.encode(jsonEncode(mapping.toJson())),
    );
    if (format == ModelResourceFormat.live2d) {
      final model = await LocalLive2dStore.instance.importPackage(
        bytes,
        characterId: widget.characterId,
        manifestOverride: mapping.toLive2dManifest(catalog),
        performanceMapping: mappingBytes,
      );
      await _completeModelImport(model.id, importedPackage, format);
      if (mounted) {
        widget.onImported(
          characterAppearanceById(model.id, characterId: widget.characterId),
        );
      }
      return;
    }
    if (format != ModelResourceFormat.spine) return;
    final gestureMapping = preserveTemplate
        ? null
        : Uint8List.fromList(
            utf8.encode(jsonEncode(mapping.toSpineGesture(catalog))),
          );
    final files = await LocalSkinStore.instance.preparePackage(
      bytes,
      gestureMapping: gestureMapping,
      performanceMapping: mappingBytes,
      preserveCompatibleTemplate: preserveTemplate,
    );
    final base = files.keys
        .firstWhere((name) => name.endsWith('.atlas'))
        .replaceFirst('.atlas', '');
    parseCharacterMotionGroups(utf8.decode(files['${base}_gesture.json']!));
    final bundle = ProtectedCharacterAssetBundle({
      for (final entry in files.entries) 'import/${entry.key}': entry.value,
    });
    if (isSpine36(catalog.runtimeVersion)) {
      final model = Spine36Model(
        files['$base.json']!,
        files['$base.atlas']!,
        files['$base.png']!,
      );
      final animations = (await model.validate()).toSet();
      for (final target in [
        mapping.idle!,
        ...mapping.actions.values.map((binding) => binding.target),
        ...mapping.expressions.values.map((binding) => binding.target),
        ...mapping.parameters.values.map((binding) => binding.target),
      ]) {
        final resource = catalog.resourceById(target)!;
        if (!animations.contains(
          resource.native['animation'] ?? resource.name,
        )) {
          throw const FormatException('映射引用的动画无法由 Spine 3.6 运行库播放');
        }
      }
    } else {
      final atlas = await Atlas.fromAsset('import/$base.atlas', bundle: bundle);
      try {
        final skeleton = await SkeletonData.fromAsset(
          atlas,
          'import/${catalog.entryFile.split('/').last}',
          bundle: bundle,
        );
        try {
          final idle = catalog.resourceById(mapping.idle!)!;
          final idleName = idle.native['animation'] as String? ?? idle.name;
          if (skeleton.findAnimation(idleName) == null) {
            throw const FormatException('Missing compatible idle animation');
          }
          if (preserveTemplate) {
            final requiredIdles =
                characterAppearances
                    .where(
                      (appearance) => appearance.id == compatibleTemplate!.id,
                    )
                    .firstOrNull
                    ?.idleAnimations ??
                const <String>[];
            if (requiredIdles.isEmpty ||
                requiredIdles.any(
                  (name) => skeleton.findAnimation(name) == null,
                )) {
              throw const FormatException('骨架不包含此操纵模板所需的基础动画，请改用通用映射。');
            }
          }
          for (final binding in [
            ...mapping.actions.values,
            ...mapping.expressions.values,
            ...mapping.parameters.values,
          ]) {
            final resource = catalog.resourceById(binding.target)!;
            final animation =
                resource.native['animation'] as String? ?? resource.name;
            if (skeleton.findAnimation(animation) == null) {
              throw const FormatException('映射引用的动画无法由当前骨架播放');
            }
          }
        } finally {
          skeleton.dispose();
        }
      } finally {
        atlas.dispose();
      }
    }
    final record = await LocalSkinStore.instance.importPackage(
      bytes,
      characterId: widget.characterId,
      gestureMapping: gestureMapping,
      performanceMapping: mappingBytes,
      preserveCompatibleTemplate: preserveTemplate,
    );
    await _completeModelImport(record['id']!, importedPackage, format);
    if (mounted) {
      widget.onImported(
        characterAppearanceById(record['id']!, characterId: widget.characterId),
      );
    }
  }

  Future<void> _completeModelImport(
    String modelId,
    DecodedModelPackage? package,
    ModelResourceFormat format,
  ) async {
    registerLocalSkinAppearances();
    try {
      await _restorePackageData(modelId, package);
    } on Object catch (error, stack) {
      try {
        if (format == ModelResourceFormat.live2d) {
          await LocalLive2dStore.instance.removeImportedModel(
            modelId,
            characterId: widget.characterId,
          );
        } else {
          await LocalSkinStore.instance.removeImportedModel(
            modelId,
            characterId: widget.characterId,
          );
        }
        characterAppearances.removeWhere((item) => item.id == modelId);
      } on Object catch (rollbackError, rollbackStack) {
        RuntimeLog.instance.error(
          'ModelImportRollback',
          rollbackError,
          rollbackStack,
        );
        throw StateError('模型数据导入失败，清理未完成。原有模型数据已保留，请重启后检查模型库。');
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> _restorePackageData(
    String modelId,
    DecodedModelPackage? package,
  ) async {
    if (package == null) return;
    final controller = widget.controller;
    if (controller == null) {
      throw const FormatException('恢复模型数据需要从应用模型导入入口进入');
    }
    await controller.restoreModelPackageData(
      modelId,
      session: package.session,
      saveSlots: package.saveSlots,
      displayName: (package.manifest['label'] as String).characters
          .take(120)
          .toString(),
    );
    if (package.attachments.isNotEmpty) {
      await ModelPackageStore.instance.saveAttachments(
        modelId,
        package.attachments,
      );
      if (package.manifest['format'] == 'spine') {
        await LocalSkinStore.instance.restoreModelAttachments(
          modelId,
          characterId: widget.characterId,
        );
      }
    }
  }

  Future<CharacterAppearance?> _chooseTextureTarget() async {
    final appearances = widget.appearances
        .where((appearance) => appearance.hasImportedSpine)
        .toList();
    if (appearances.isEmpty) {
      throw FormatException(
        t(
          '请先导入 Spine 模型',
          'Import a Spine model first',
          '先に Spine モデルを読み込んでください',
        ),
      );
    }
    return showDialog<CharacterAppearance>(
      context: context,
      useRootNavigator: false,
      useSafeArea: !widget.embedded,
      builder: (dialogContext) => AlertDialog(
        insetPadding: EdgeInsets.all(widget.embedded ? 12 : 24),
        title: Text(t('选择贴图对应的模型', 'Choose model for texture', 'テクスチャのモデルを選択')),
        contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        content: SizedBox(
          width: 360,
          height: (MediaQuery.sizeOf(dialogContext).height * .5).clamp(
            160.0,
            400.0,
          ),
          child: ListView.builder(
            itemCount: appearances.length,
            itemBuilder: (context, index) {
              final appearance = appearances[index];
              return ListTile(
                key: ValueKey('texture-target-${appearance.id}'),
                leading: const Icon(Icons.checkroom_outlined),
                title: Text(appearance.label, maxLines: 2),
                onTap: () => Navigator.of(dialogContext).pop(appearance),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(t('取消', 'Cancel', 'キャンセル')),
          ),
        ],
      ),
    );
  }

  Future<void> _importTexture() async {
    final bytes = await _pick('png');
    if (bytes == null || !mounted) return;
    final appearance = await _chooseTextureTarget();
    if (appearance == null || !mounted) return;
    final files = await ProtectedCharacterAssets.originalFilesFor(
      appearance.assetName,
      characterId: appearance.characterId,
    );
    final pngs = files.entries
        .where((entry) => entry.key.endsWith('.png'))
        .toList();
    if (pngs.length != 1) {
      throw const FormatException('Expected one texture page');
    }
    if (pngSize(bytes) != pngSize(pngs.single.value)) {
      throw FormatException(
        'PNG size ${pngSize(bytes)}; expected ${pngSize(pngs.single.value)}',
      );
    }
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
    await LocalSkinStore.instance.importTexture(
      appearance.assetName,
      bytes,
      pngs.single.value,
    );
    ProtectedCharacterAssets.clearCache();
    if (mounted) widget.onTextureChanged(appearance);
  }

  Widget _action({
    required Key key,
    required String label,
    required VoidCallback onTap,
  }) {
    final color = Theme.of(context).colorScheme.onSurface;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        key: key,
        onTap: _busy ? null : onTap,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxHeight < 105 || constraints.maxWidth < 200;
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(
                    width: (constraints.maxWidth - 12).clamp(1.0, 260.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.add_rounded,
                          size: compact ? 40 : 64,
                          color: color,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          label,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          style: TextStyle(
                            color: color,
                            fontSize: compact ? 13 : 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Column(
        children: [
          Expanded(
            child: _action(
              key: const ValueKey('import-outfit-zip'),
              label: t(
                '导入模型 / 场景 ZIP',
                'Import model / scene ZIP',
                'モデル・背景 ZIP',
              ),
              onTap: () => _run(_importZip),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _action(
              key: const ValueKey('import-outfit-texture'),
              label: t('导入贴图', 'Import texture', 'テクスチャを読み込む'),
              onTap: () => _run(_importTexture),
            ),
          ),
        ],
      ),
      if (_busy) const Center(child: CircularProgressIndicator()),
      if (_error != null)
        Positioned(
          left: 12,
          right: 12,
          bottom: 6,
          child: Text(
            _error!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
          ),
        ),
    ],
  );
}
