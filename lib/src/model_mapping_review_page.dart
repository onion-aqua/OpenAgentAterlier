import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'model_mapping_service.dart';
import 'model_performance_mapping.dart';
import 'model_resource_catalog.dart';

/// A mapping is a proposal until the user reviews it and local validation
/// accepts every reference. Nothing is written to the model store on this page.
class ModelMappingReviewPage extends StatefulWidget {
  const ModelMappingReviewPage({
    super.key,
    required this.catalog,
    this.controller,
    this.service,
    this.compatibleTemplateLabel,
    this.onPreserveTemplateChanged,
  });

  final ModelResourceCatalog catalog;
  final AppController? controller;
  final ModelMappingService? service;
  final String? compatibleTemplateLabel;
  final ValueChanged<bool>? onPreserveTemplateChanged;

  @override
  State<ModelMappingReviewPage> createState() => _ModelMappingReviewPageState();
}

class _ModelMappingReviewPageState extends State<ModelMappingReviewPage> {
  final _editor = TextEditingController();
  ModelPerformanceMapping? _mapping;
  bool _busy = false;
  bool _analyzed = false;
  bool _preserveTemplate = true;
  String? _error;

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  Future<void> _analyze() async {
    final controller = widget.controller;
    if (controller == null) {
      setState(() => _error = '请从聊天界面的模型导入入口进入，并配置 AI 接口。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final mapping = await (widget.service ?? ModelMappingService()).analyze(
        widget.catalog,
        controller: controller,
      );
      if (!mounted) return;
      setState(() {
        _analyzed = true;
        _mapping = mapping;
        _editor.text = const JsonEncoder.withIndent('  ')
            .convert(mapping.toJson());
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = '映射分析未完成：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _validate() {
    try {
      final mapping = ModelPerformanceMapping.parse(
        _editor.text,
        catalog: widget.catalog,
      );
      setState(() {
        _mapping = mapping;
        _error = null;
      });
    } on Object catch (error) {
      setState(() {
        _mapping = null;
        _error = '映射尚未通过校验：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = widget.catalog;
    final mapping = _mapping;
    final counts = <String, int>{};
    for (final resource in catalog.resources) {
      counts.update(resource.kind, (n) => n + 1, ifAbsent: () => 1);
    }
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('模型适配')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              '${catalog.format.name.toUpperCase()} · ${catalog.runtimeVersion}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(catalog.entryFile),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final entry in counts.entries)
                  Chip(label: Text('${entry.key} ${entry.value}')),
              ],
            ),
            if (catalog.compatibilityIssues.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final issue in catalog.compatibilityIssues)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    issue,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 12),
            const Text('使用已配置的 AI 接口分析动作、表情和口型。仅发送资源目录与必要的结构摘要，可能产生模型调用费用。'),
            const SizedBox(height: 8),
            const Text('不确定的编号动作会保留为未绑定；分析完成后可以检查和修改映射。'),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('model-mapping-analyze'),
              onPressed: _busy ? null : _analyze,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_outlined),
              label: Text(
                _busy
                    ? '正在分析资源…'
                    : _analyzed
                    ? '重新分析'
                    : '使用 LLM 生成映射',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                key: const ValueKey('model-mapping-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_analyzed) ...[
              const SizedBox(height: 16),
              if (widget.compatibleTemplateLabel case final label?)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('保留完整操纵模板：$label'),
                  subtitle: const Text(
                    '推荐。保留原有组合动作与驱动；本次 AI 映射同时存档。取消后使用通用映射控制。',
                  ),
                  value: _preserveTemplate,
                  onChanged: _busy
                      ? null
                      : (value) {
                          setState(() => _preserveTemplate = value ?? true);
                          widget.onPreserveTemplateChanged?.call(
                            _preserveTemplate,
                          );
                        },
                ),
              if (mapping != null) ...[
                Text(
                  mapping.label,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  '动作 ${mapping.actions.length} · 表情 ${mapping.expressions.length} · 参数 ${mapping.parameters.length}',
                ),
                if (mapping.idle case final idle?)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('待机'),
                    subtitle: Text(catalog.resourceById(idle)?.name ?? idle),
                  ),
                for (final section in {
                  '动作': mapping.actions,
                  '表情': mapping.expressions,
                  '参数': mapping.parameters,
                }.entries)
                  for (final entry in section.value.entries)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${section.key} · ${entry.key} → ${catalog.resourceById(entry.value.target)?.name ?? entry.value.target}',
                      ),
                      subtitle: Text(
                        '${entry.value.description}\n依据：${entry.value.evidence}',
                      ),
                      trailing: Text(
                        '${(entry.value.confidence * 100).round()}%',
                      ),
                    ),
                for (final note in mapping.notes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(note),
                  ),
                if (mapping.parameters.isNotEmpty)
                  const Text('当前自动驱动口型；其他参数映射会保存，供后续控制器接入。'),
              ],
              ExpansionTile(
                key: const ValueKey('model-mapping-editor-section'),
                tilePadding: EdgeInsets.zero,
                title: const Text('编辑映射 JSON'),
                children: [
                  TextField(
                    key: const ValueKey('model-mapping-editor'),
                    controller: _editor,
                    minLines: 8,
                    maxLines: 18,
                    maxLength: 128 * 1024,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                    onChanged: (_) => _validate(),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
              TextButton.icon(
                onPressed: mapping == null
                    ? null
                    : () async {
                        await Clipboard.setData(
                          ClipboardData(text: _editor.text),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('映射已复制')),
                          );
                        }
                      },
                icon: const Icon(Icons.copy_outlined),
                label: const Text('复制映射'),
              ),
              if (!catalog.runtimeSupported)
                const Text('映射可以复制保存。当前运行库尚不能加载此格式或版本，完成对应渲染适配后才能导入。'),
            ],
          ],
        ),
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.all(16),
          child: FilledButton(
            key: const ValueKey('model-mapping-confirm'),
            onPressed:
                !_busy &&
                    _analyzed &&
                    mapping != null &&
                    catalog.runtimeSupported
                ? () => Navigator.pop(context, mapping)
                : null,
            child: const Text('确认映射并导入'),
          ),
        ),
      ),
    );
  }
}
