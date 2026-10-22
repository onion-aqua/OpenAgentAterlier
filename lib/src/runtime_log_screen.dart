import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_localization.dart';
import 'glass_ui.dart';
import 'runtime_log.dart';

class RuntimeLogScreen extends StatefulWidget {
  const RuntimeLogScreen({
    super.key,
    required this.language,
    this.liquidGlass = false,
    required this.onMenuPressed,
    this.embedded = false,
  });
  final AppLanguage language;
  final bool liquidGlass;
  final VoidCallback onMenuPressed;
  final bool embedded;
  @override
  State<RuntimeLogScreen> createState() => _RuntimeLogScreenState();
}

class _RuntimeLogScreenState extends State<RuntimeLogScreen> {
  RuntimeLogModule? _module;
  RuntimeLogLevel? _level;
  bool _filtersExpanded = false;
  final _scrollController = ScrollController(keepScrollOffset: false);
  final _filterScrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    _filterScrollController.dispose();
    super.dispose();
  }

  void _changeFilters({RuntimeLogModule? module, RuntimeLogLevel? level}) {
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    setState(() {
      _module = module;
      _level = level;
    });
  }

  String label(RuntimeLogModule module) => switch (module) {
    RuntimeLogModule.llm => 'LLM',
    RuntimeLogModule.tts => 'TTS',
    RuntimeLogModule.expression => widget.language.text(
      '表情规划',
      'Expression',
      '表情計画',
    ),
    RuntimeLogModule.action => widget.language.text('动作规划', 'Action', '動作計画'),
    RuntimeLogModule.speech => widget.language.text(
      '语音规划',
      'Speech planning',
      '音声計画',
    ),
    RuntimeLogModule.memory => widget.language.text('记忆', 'Memory', '記憶'),
    RuntimeLogModule.translation => widget.language.text(
      '翻译',
      'Translation',
      '翻訳',
    ),
    RuntimeLogModule.character => widget.language.text(
      '角色',
      'Character',
      'キャラクター',
    ),
    RuntimeLogModule.storage => widget.language.text('数据', 'Data', 'データ'),
    RuntimeLogModule.singing => widget.language.text('歌唱规划', 'Singing', '歌唱計画'),
    RuntimeLogModule.soundscape => widget.language.text(
      '场景音频',
      'Soundscape',
      '環境音',
    ),
    RuntimeLogModule.alarm => widget.language.text('闹钟', 'Alarm', 'アラーム'),
    RuntimeLogModule.relay => widget.language.text(
      'PC 联动',
      'PC Agent',
      'PC 連携',
    ),
    RuntimeLogModule.system => widget.language.text(
      '系统 / 其他',
      'System / Other',
      'システム / その他',
    ),
  };
  Color color(RuntimeLogModule module) {
    final hue = switch (module) {
      RuntimeLogModule.llm => 210.0,
      RuntimeLogModule.tts => 150.0,
      RuntimeLogModule.expression => 290.0,
      RuntimeLogModule.action => 30.0,
      RuntimeLogModule.speech => 330.0,
      RuntimeLogModule.memory => 180.0,
      RuntimeLogModule.translation => 250.0,
      RuntimeLogModule.character => 70.0,
      RuntimeLogModule.storage => 10.0,
      RuntimeLogModule.singing => 310.0,
      RuntimeLogModule.soundscape => 165.0,
      RuntimeLogModule.alarm => 45.0,
      RuntimeLogModule.relay => 225.0,
      RuntimeLogModule.system => 0.0,
    };
    return HSLColor.fromAHSL(
      1,
      hue,
      module == RuntimeLogModule.system ? 0 : .65,
      Theme.of(context).brightness == Brightness.dark ? .72 : .32,
    ).toColor();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: RuntimeLog.instance,
    builder: (context, _) {
      final allEntries = RuntimeLog.instance.entries;
      final entries = allEntries.reversed
          .where(
            (entry) =>
                (_module == null || entry.module == _module) &&
                (_level == null || entry.level == _level),
          )
          .toList(growable: false);
      final moduleCounts = <RuntimeLogModule, int>{};
      var matchingLevelCount = 0;
      for (final entry in allEntries) {
        // Category counts describe what selecting a chip will show with
        // the current severity filter, rather than unrelated stored rows.
        if (_level != null && entry.level != _level) continue;
        matchingLevelCount++;
        moduleCounts.update(
          entry.module,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
      final entryIndexes = {
        for (var index = 0; index < entries.length; index++)
          entries[index].identity: index,
      };
      final language = widget.language;
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: glassPageHeaderColor(context),
          automaticallyImplyLeading: false,
          title: Padding(
            padding: EdgeInsets.only(left: widget.embedded ? 40 : 58),
            child: Text(language.text('运行日志', 'Runtime logs', '実行ログ')),
          ),
          actions: [
            Semantics(
              container: true,
              child: IconButton(
                onPressed: RuntimeLog.instance.entries.isEmpty
                    ? null
                    : () => RuntimeLog.instance.clear(),
                tooltip: language.text('清空全部日志', 'Clear all logs', '全ログを消去'),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
            Semantics(
              container: true,
              child: IconButton(
                onPressed: entries.isEmpty
                    ? null
                    : () => Clipboard.setData(
                        ClipboardData(
                          text: entries.map((e) => e.formatted).join('\n\n'),
                        ),
                      ),
                tooltip: language.text(
                  '复制筛选结果',
                  'Copy filtered logs',
                  '絞り込み結果をコピー',
                ),
                icon: const Icon(Icons.copy_outlined),
              ),
            ),
          ],
        ),
        body: GlassPageSurface(
          liquidGlass: widget.liquidGlass,
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              children: [
                InkWell(
                  key: const ValueKey('runtime-log-filter-toggle'),
                  onTap: () =>
                      setState(() => _filtersExpanded = !_filtersExpanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.filter_alt_outlined, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${_module == null ? language.text('全部分类', 'All categories', '全カテゴリ') : label(_module!)} · ${_level?.label ?? language.text('全部级别', 'All levels', '全レベル')}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text('${entries.length} / ${allEntries.length}'),
                        const SizedBox(width: 4),
                        Icon(
                          _filtersExpanded
                              ? Icons.expand_less
                              : Icons.expand_more,
                        ),
                      ],
                    ),
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  alignment: Alignment.topCenter,
                  child: _filtersExpanded
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: constraints.maxHeight * .4,
                              ),
                              child: Scrollbar(
                                controller: _filterScrollController,
                                thumbVisibility: true,
                                child: SingleChildScrollView(
                                  controller: _filterScrollController,
                                  key: const ValueKey('runtime-log-categories'),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 6,
                                    ),
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: [
                                          ChoiceChip(
                                            label: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  language.text(
                                                    '全部',
                                                    'All',
                                                    'すべて',
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                Text('$matchingLevelCount'),
                                              ],
                                            ),
                                            selected: _module == null,
                                            onSelected: (_) =>
                                                _changeFilters(level: _level),
                                          ),
                                          for (final module
                                              in RuntimeLogModule.values)
                                            ChoiceChip(
                                              key: ValueKey(
                                                'runtime-log-filter-${module.name}',
                                              ),
                                              avatar: Icon(
                                                Icons.circle,
                                                size: 10,
                                                color: color(module),
                                              ),
                                              label: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(label(module)),
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    '${moduleCounts[module] ?? 0}',
                                                  ),
                                                ],
                                              ),
                                              selected: _module == module,
                                              onSelected: (_) => _changeFilters(
                                                module: module,
                                                level: _level,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: DropdownButton<RuntimeLogLevel>(
                                      isExpanded: true,
                                      value: _level,
                                      hint: Text(
                                        language.text(
                                          '全部级别',
                                          'All levels',
                                          '全レベル',
                                        ),
                                      ),
                                      items: [
                                        DropdownMenuItem(
                                          value: null,
                                          child: Text(
                                            language.text(
                                              '全部级别',
                                              'All levels',
                                              '全レベル',
                                            ),
                                          ),
                                        ),
                                        for (final level
                                            in RuntimeLogLevel.values)
                                          DropdownMenuItem(
                                            value: level,
                                            child: Text(level.label),
                                          ),
                                      ],
                                      onChanged: (value) => _changeFilters(
                                        module: _module,
                                        level: value,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  if (_module != null || _level != null)
                                    IconButton(
                                      key: const ValueKey(
                                        'runtime-log-reset-filters',
                                      ),
                                      tooltip: language.text(
                                        '重置筛选',
                                        'Reset filters',
                                        '絞り込みをリセット',
                                      ),
                                      onPressed: () => _changeFilters(),
                                      icon: const Icon(
                                        Icons.filter_alt_off_outlined,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
                Expanded(
                  child: entries.isEmpty
                      ? Center(
                          child: SingleChildScrollView(
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    allEntries.isEmpty
                                        ? language.text(
                                            '暂无运行日志',
                                            'No logs yet',
                                            '実行ログなし',
                                          )
                                        : language.text(
                                            '暂无匹配日志',
                                            'No matching logs',
                                            '該当ログなし',
                                          ),
                                  ),
                                  if (allEntries.isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      '${_module == null ? language.text('全部分类', 'All categories', '全カテゴリ') : label(_module!)} · ${_level?.label ?? language.text('全部级别', 'All levels', '全レベル')}',
                                      textAlign: TextAlign.center,
                                    ),
                                    TextButton(
                                      onPressed: () => _changeFilters(),
                                      child: Text(
                                        language.text(
                                          '显示全部日志',
                                          'Show all logs',
                                          'すべてのログを表示',
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          key: ValueKey('${_module?.name}:${_level?.name}'),
                          controller: _scrollController,
                          padding: const EdgeInsets.all(12),
                          itemCount: entries.length,
                          findChildIndexCallback: (key) {
                            if (key is! ValueKey<String>) return null;
                            return entryIndexes[key.value];
                          },
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            final text = entry.displayMessage;
                            final long =
                                text.length > 500 ||
                                '\n'.allMatches(text).length > 8;
                            final severity = switch (entry.level) {
                              RuntimeLogLevel.info => color(entry.module),
                              RuntimeLogLevel.warning =>
                                Theme.of(context).brightness == Brightness.dark
                                    ? Colors.amber.shade200
                                    : Colors.brown.shade700,
                              RuntimeLogLevel.error => Theme.of(
                                context,
                              ).colorScheme.error,
                            };
                            return Padding(
                              // Appending a log moves existing rows by one.
                              // Keep expansion, selection and semantics attached
                              // to the entry rather than its current list index.
                              key: ValueKey(entry.identity),
                              padding: EdgeInsets.only(
                                bottom: index == entries.length - 1 ? 0 : 12,
                              ),
                              child: GlassContentCard(
                                key: ValueKey(
                                  'runtime-log-card-${entry.identity}',
                                ),
                                liquidGlass: widget.liquidGlass,
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Wrap(
                                        spacing: 10,
                                        runSpacing: 4,
                                        children: [
                                          Text(
                                            '${label(entry.module)} · ${entry.source}',
                                            style: TextStyle(
                                              color: color(entry.module),
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          Text(
                                            entry.level.label,
                                            style: TextStyle(
                                              color: severity,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          if (entry.repeatCount > 1)
                                            Text(
                                              language.text(
                                                '重复 ${entry.repeatCount} 次',
                                                'Repeated ${entry.repeatCount} times',
                                                '${entry.repeatCount} 回発生',
                                              ),
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall,
                                            ),
                                          Text(
                                            entry.timestamp
                                                .toLocal()
                                                .toIso8601String()
                                                .replaceFirst('T', ' '),
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall,
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      if (long)
                                        ExpansionTile(
                                          tilePadding: EdgeInsets.zero,
                                          shape: const Border(),
                                          collapsedShape: const Border(),
                                          title: Text(
                                            text.split('\n').take(3).join(' '),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          children: [
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                bottom: 8,
                                              ),
                                              child: Align(
                                                alignment: Alignment.centerLeft,
                                                child: SelectableText(
                                                  text,
                                                  style: const TextStyle(
                                                    fontFamily: 'monospace',
                                                    fontSize: 12,
                                                    height: 1.5,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        )
                                      else
                                        SelectableText(
                                          text,
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 12,
                                            height: 1.5,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
