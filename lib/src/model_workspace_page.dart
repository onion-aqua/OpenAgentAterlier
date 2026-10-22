import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'app_localization.dart';
import 'character_appearance.dart';
import 'model_package_store.dart';
import 'settings_detail_page.dart';
import 'skin_import_controls.dart';

/// A portable model package owns its role settings and conversation data.
/// Service connections and credentials are device configuration.
class ModelWorkspacePage extends StatefulWidget {
  const ModelWorkspacePage({super.key, required this.controller});
  final AppController controller;

  @override
  State<ModelWorkspacePage> createState() => _ModelWorkspacePageState();
}

class _ModelWorkspacePageState extends State<ModelWorkspacePage> {
  bool _busy = false;
  String? _error;
  String _t(String zh, String en, String ja) =>
      widget.controller.interfaceLanguage.text(zh, en, ja);

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename() async {
    final controller = widget.controller;
    final scope = controller.activeConversationScopeId;
    final input = TextEditingController(
      text: controller.activeModelDisplayName,
    );
    final name = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AlertDialog(
        title: Text(_t('角色名称', 'Character name', 'キャラクター名')),
        content: TextField(
          controller: input,
          maxLength: 120,
          autofocus: true,
          decoration: InputDecoration(
            helperText: _t(
              '设定中用于称呼当前模型的角色名称',
              'Name used for this model in character settings',
              'このモデルのキャラクター設定で使う名前',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_t('取消', 'Cancel', 'キャンセル')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: Text(_t('保存', 'Save', '保存')),
          ),
        ],
      ),
    );
    input.dispose();
    if (name == null || scope != controller.activeConversationScopeId) return;
    await controller.setModelDisplayName(name);
  }

  Future<void> _export() async {
    final controller = widget.controller;
    final id = controller.activeModelId;
    if (id == null) {
      throw StateError(
        _t('请先选择一个已导入的模型', 'Select an imported model first', '先にモデルを選択してください'),
      );
    }
    await controller.flushModelSession();
    final bytes = await ModelPackageStore.instance.packageBytes(id);
    if (!mounted || controller.activeModelId != id) return;
    final result = await FilePicker.saveFile(
      fileName: 'agent-atelier-model-$id.zip',
      bytes: bytes,
      mimeType: 'application/zip',
    );
    if (mounted && result != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _t(
              '模型、设定、对话和存档已导出',
              'Model, settings, conversations and saves exported',
              'モデル・設定・会話・セーブを書き出しました',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _import() async {
    final controller = widget.controller;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: false,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: 340,
          child: SkinImportControls(
            controller: controller,
            characterId: 'ryza',
            appearances: importedModelAppearances(),
            language: controller.interfaceLanguage,
            onImported: (appearance) async {
              if (sheetContext.mounted) Navigator.pop(sheetContext);
              await _run(
                () => controller.setCharacterAppearance(appearance.id),
              );
            },
            onTextureChanged: (_) {},
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final id = controller.activeModelId;
      return SettingsDetailPage(
        title: Text(_t('模型档案与数据', 'Model profile & data', 'モデルの設定とデータ')),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                title: Text(
                  id == null
                      ? _t('尚未选择导入模型', 'No imported model selected', 'モデル未選択')
                      : controller.activeModelDisplayName,
                ),
                subtitle: Text(
                  id ??
                      _t(
                        '导入模型以创建独立档案；旧数据仍然保留',
                        'Import a model to create its own profile. Existing data is preserved.',
                        'モデルを読み込むと専用の設定を作成します。既存データは保持します。',
                      ),
                ),
                leading: const Icon(Icons.account_box_outlined),
                trailing: id == null ? null : const Icon(Icons.edit_outlined),
                onTap: id == null || _busy ? null : () => _run(_rename),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _t(
                    '当前模型独立保存用户设定、人物设定、世界设定、对话、记忆和存档。切换模型时切换对应的数据；AI 与语音服务连接仍由应用共享。',
                    'Each model owns its user, character and world settings, conversations, memory and saves. Selecting a model switches its data. AI and voice service connections are shared on this device.',
                    'ユーザー・キャラクター・世界の設定、会話、記憶、セーブはモデルごとに保存します。モデルを選ぶとデータも切り替わります。AIと音声サービスの接続設定は端末で共用します。',
                  ),
                ),
              ),
              if (controller.modelScopeRestoreError != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    controller.modelScopeRestoreError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              FilledButton.icon(
                key: const ValueKey('export-model-package'),
                onPressed: id == null || _busy ? null : () => _run(_export),
                icon: const Icon(Icons.archive_outlined),
                label: Text(
                  _t(
                    '导出模型与数据 ZIP',
                    'Export model & data ZIP',
                    'モデルとデータをZIPで書き出す',
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  _t(
                    '压缩包包含模型资源和当前模型档案。模型包不包含服务地址、API Key、OAuth 或 PC Agent 凭证；收藏的语音和本地 TTS 模型仍使用各自的导出方式。',
                    'The ZIP contains model resources and its profile. It excludes service addresses, API keys, OAuth and PC Agent credentials. Export saved audio and local TTS models separately.',
                    'ZIPにはモデル素材と専用データを含みます。サービスURL、APIキー、OAuth、PC Agent認証情報は含みません。お気に入り音声とローカルTTSモデルは別途書き出してください。',
                  ),
                ),
              ),
              OutlinedButton.icon(
                key: const ValueKey('import-model-package'),
                onPressed: _busy ? null : _import,
                icon: const Icon(Icons.file_open_outlined),
                label: Text(
                  _t(
                    '导入模型或模型与数据 ZIP',
                    'Import model or model & data ZIP',
                    'モデルまたはモデルとデータZIPを読み込む',
                  ),
                ),
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
