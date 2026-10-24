import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_identity.dart';
import 'app_localization.dart';
import 'glass_ui.dart';

/// Full-package desktop updates use an independently configured release page.
/// An empty configuration has no endpoint and cannot open a former app release.
class DesktopUpdatesPage extends StatefulWidget {
  const DesktopUpdatesPage({
    super.key,
    required this.language,
    required this.liquidGlass,
    this.openRelease,
    this.releasePage,
  });

  final AppLanguage language;
  final bool liquidGlass;
  final Future<bool> Function(Uri uri)? openRelease;
  final Uri? releasePage;

  static Uri? get releaseUrl {
    const value = String.fromEnvironment('OAA_DESKTOP_RELEASE_URL');
    final uri = Uri.tryParse(value);
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty &&
            uri.fragment.isEmpty
        ? uri
        : null;
  }

  @override
  State<DesktopUpdatesPage> createState() => _DesktopUpdatesPageState();
}

class _DesktopUpdatesPageState extends State<DesktopUpdatesPage> {
  bool _opening = false;
  bool _failed = false;

  Uri? get _release {
    final uri = widget.releasePage ?? DesktopUpdatesPage.releaseUrl;
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty &&
            uri.fragment.isEmpty
        ? uri
        : null;
  }

  String _t(String zh, String en, String ja) =>
      widget.language.text(zh, en, ja);

  Future<void> _open() async {
    final release = _release;
    if (_opening || release == null) return;
    if (release.scheme != 'https' ||
        release.host.isEmpty ||
        release.userInfo.isNotEmpty) {
      return;
    }
    setState(() {
      _opening = true;
      _failed = false;
    });
    var opened = false;
    try {
      opened =
          await (widget.openRelease?.call(release) ??
              launchUrl(release, mode: LaunchMode.externalApplication));
    } on Object {
      opened = false;
    }
    if (!mounted) return;
    setState(() {
      _opening = false;
      _failed = !opened;
    });
  }

  @override
  Widget build(BuildContext context) => GlassPageSurface(
    liquidGlass: widget.liquidGlass,
    child: Scaffold(
      key: const ValueKey('desktop-updates-page'),
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: glassPageHeaderColor(context),
        title: Text(_t('PC 版下载与更新', 'PC downloads & updates', 'PC版のダウンロードと更新')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const ListTile(
            leading: Icon(Icons.desktop_windows_rounded),
            title: Text('$appDisplayName Windows'),
            subtitle: Text('Windows x64'),
          ),
          const SizedBox(height: 12),
          Text(
            _t(
              '下载完整 Windows ZIP，解压到新目录。退出旧版本后运行 OpenAgentAtelier.exe，并保留同目录的 DLL 和 data 文件夹。',
              'Extract the complete Windows ZIP to a new folder. Exit the old version and run OpenAgentAtelier.exe, keeping its DLLs and data folder together.',
              'Windows ZIPを新しいフォルダーにすべて展開し、旧版を終了してOpenAgentAtelier.exeを起動します。DLLとdataフォルダーを同じ場所に保管してください。',
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _t(
              '存档、聊天和设置保存在当前 Windows 用户的数据目录。PC 版使用完整包更新。',
              'Saves, conversations and settings stay in the current Windows user data folder. PC updates use the complete package.',
              'セーブ、会話、設定は現在のWindowsユーザーのデータ領域に保存されます。PC版の更新には完全パッケージを使用します。',
            ),
          ),
          if (_release == null) ...[
            const SizedBox(height: 16),
            Text(
              _t(
                '此构建尚未配置 OpenAgentAtelier 独立发布地址。',
                'This build has no OpenAgentAtelier release page configured.',
                'このビルドにはOpenAgentAtelier専用の配布先が設定されていません。',
              ),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const ValueKey('desktop-release-download'),
            onPressed: _opening || _release == null ? null : _open,
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(_t('前往发布页', 'Open release page', '配布ページを開く')),
          ),
          if (_failed) ...[
            const SizedBox(height: 16),
            Text(
              _t(
                '未能打开浏览器，可复制以下地址：',
                'Could not open the browser. Copy this URL:',
                'ブラウザーを開けません。以下のURLをコピーしてください：',
              ),
            ),
            SelectableText(_release.toString()),
          ],
        ],
      ),
    ),
  );
}
