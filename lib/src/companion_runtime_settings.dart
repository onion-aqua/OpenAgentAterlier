import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'android_companion_runtime.dart';
import 'app_localization.dart';
import 'glass_ui.dart';

/// Android's notification and optional call-detection controls. Background
/// companionship starts by default; opening this section never asks permission.
class CompanionRuntimeSettings extends StatefulWidget {
  const CompanionRuntimeSettings({super.key, required this.language});

  final AppLanguage language;

  @override
  State<CompanionRuntimeSettings> createState() =>
      _CompanionRuntimeSettingsState();
}

class _CompanionRuntimeSettingsState extends State<CompanionRuntimeSettings>
    with WidgetsBindingObserver {
  final _runtime = AndroidCompanionRuntime.instance;
  bool _busy = false;
  bool _actionFailed = false;

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  String t(String zh, String en, String ja) => widget.language.text(zh, en, ja);

  @override
  void initState() {
    super.initState();
    if (_supported) {
      WidgetsBinding.instance.addObserver(this);
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_supported && state == AppLifecycleState.resumed) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    try {
      await _runtime.refresh();
    } on Object {
      if (mounted) setState(() => _actionFailed = true);
    }
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _actionFailed = false;
    });
    try {
      await action();
      await _runtime.refresh();
    } on Object {
      if (mounted) setState(() => _actionFailed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestNotifications() async {
    final status = await Permission.notification.request();
    if (status.isPermanentlyDenied || status.isRestricted) {
      await openAppSettings();
      return;
    }
    if (status.isGranted) {
      await _runtime.start();
      await _runtime.refresh();
      // Android can allow app notifications while this specific channel is off.
      if (!_runtime.notificationsAllowed) await openAppSettings();
    }
  }

  Future<void> _requestPhonePermission() async {
    final status = await Permission.phone.request();
    if (status.isPermanentlyDenied || status.isRestricted) {
      await openAppSettings();
    }
  }

  String _status() {
    if (_runtime.starting) {
      return t(
        '正在准备后台陪伴',
        'Starting background companionship',
        'バックグラウンド動作を準備中',
      );
    }
    if (_runtime.running) {
      return _runtime.notificationsAllowed
          ? t('后台陪伴正在运行', 'Background companionship is running', 'バックグラウンドで動作中')
          : t(
              '后台陪伴正在运行，通知未启用',
              'Background companionship is running; notifications are off',
              'バックグラウンドで動作中・通知は無効です',
            );
    }
    return _runtime.stopRequested
        ? t('后台陪伴已停止', 'Background companionship is stopped', 'バックグラウンド動作は停止中')
        : t(
            '后台陪伴尚未运行',
            'Background companionship is not running',
            'バックグラウンドでは動作していません',
          );
  }

  String _audioStatus() {
    if (_runtime.stopRequested) {
      return t(
        '后台陪伴已停止，应用声音已暂停。点击“恢复陪伴通知”后继续。',
        'Background companionship and app audio are stopped. Restore the companion notification to continue.',
        'バックグラウンド動作とアプリの音声は停止中です。「常駐通知を再表示」で再開できます。',
      );
    }
    if (_runtime.callActive) {
      return t(
        '检测到通话，应用声音已静音；通话结束后自动恢复。',
        'A call is in progress. App audio is muted and will resume after the call.',
        '通話を検出したためアプリを消音中です。通話終了後に自動で戻ります。',
      );
    }
    if (_runtime.muted) {
      return t(
        '其他应用正在使用声音，暂时静音，允许播放后自动恢复。',
        'App audio is temporarily muted while another app needs it. It will resume when available.',
        '他のアプリが音声を使用しているため一時消音中です。再生可能になると自動で戻ります。',
      );
    }
    return t(
      '电话、语音或视频通话时自动静音，结束后恢复原有音量。',
      'App audio mutes during phone, voice and video calls, then returns to its previous volume.',
      '電話・音声通話・ビデオ通話中は自動で消音し、終了後に元の音量へ戻ります。',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _runtime,
      builder: (context, _) {
        final theme = Theme.of(context);
        final busy = _busy || _runtime.starting;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: GlassContentCard(
            liquidGlass: GlassStyleScope.resolve(context),
            child: ExpansionTile(
              key: const PageStorageKey('companion-runtime-expansion'),
              initiallyExpanded: false,
              tilePadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              shape: const Border(),
              collapsedShape: const Border(),
              leading: const Icon(Icons.favorite_border),
              title: Text(
                t(
                  '后台陪伴与通话静音',
                  'Background companionship and calls',
                  'バックグラウンド動作と通話時の消音',
                ),
              ),
              subtitle: Text(_status()),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: busy
                              ? null
                              : () => _perform(_runtime.refresh),
                          icon: const Icon(Icons.refresh),
                          label: Text(t('刷新状态', 'Refresh status', '状態を更新')),
                        ),
                      ),
                      Text(
                        t(
                          '运行时显示当前角色的陪伴常驻通知。',
                          'An ongoing companion notification stays visible while the app is running.',
                          '動作中は、現在のキャラクターの常駐通知を表示します。',
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            _runtime.muted
                                ? Icons.volume_off_outlined
                                : Icons.phone_in_talk_outlined,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text(_audioStatus())),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        t(
                          '微信、QQ 等通话的识别取决于系统提供的音频状态。可选的电话权限可增强普通来电识别，不会读取联系人或录音。',
                          'Detecting calls in apps such as WeChat and QQ depends on the audio state reported by Android. The optional phone permission improves regular call detection; it does not read contacts or record calls.',
                          'WeChat・QQ などの通話は、Android が伝える音声状態に基づいて検出します。任意の電話権限で通常の着信をより確実に検出できます。連絡先の読み取りや録音は行いません。',
                        ),
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (!_runtime.notificationsAllowed)
                            OutlinedButton.icon(
                              onPressed: busy
                                  ? null
                                  : () => _perform(_requestNotifications),
                              icon: const Icon(Icons.notifications_outlined),
                              label: Text(
                                t('启用通知', 'Enable notifications', '通知を有効にする'),
                              ),
                            ),
                          OutlinedButton.icon(
                            onPressed: busy || _runtime.phoneStatePermission
                                ? null
                                : () => _perform(_requestPhonePermission),
                            icon: Icon(
                              _runtime.phoneStatePermission
                                  ? Icons.check_circle_outline
                                  : Icons.phone_outlined,
                            ),
                            label: Text(
                              _runtime.phoneStatePermission
                                  ? t(
                                      '通话权限已允许',
                                      'Phone permission enabled',
                                      '電話権限は許可済み',
                                    )
                                  : t(
                                      '增强来电识别（可选）',
                                      'Improve call detection (optional)',
                                      '着信検出を強化（任意）',
                                    ),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () =>
                                      _perform(_runtime.openBackgroundSettings),
                            icon: const Icon(Icons.settings_outlined),
                            label: Text(
                              t('厂商后台设置', 'Background settings', 'バックグラウンド設定'),
                            ),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: busy
                                ? null
                                : () => _perform(_runtime.start),
                            icon: const Icon(Icons.favorite_outline),
                            label: Text(
                              t(
                                '恢复陪伴通知',
                                'Restore companion notification',
                                '常駐通知を再表示',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        t(
                          '若后台容易中断，请在手机设置中允许自启动，并将应用设为“不限制”或“允许后台运行”；部分手机还需锁定最近任务。系统强制停止、清理或省电限制可能中断陪伴，常驻通知不能阻止系统关闭应用。',
                          'If background activity stops, allow auto-start and unrestricted background use in your phone settings. Some phones also need the app locked in Recents. Force-stop, cleanup and battery restrictions can still stop the app; an ongoing notification cannot prevent this.',
                          'バックグラウンド動作が止まる場合は、端末の設定で自動起動と制限なしのバックグラウンド動作を許可してください。端末によっては最近のアプリ画面でのロックも必要です。強制停止・クリーンアップ・省電力制限による終了を常駐通知で防ぐことはできません。',
                        ),
                        style: theme.textTheme.bodySmall,
                      ),
                      if (_runtime.manufacturer.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          t('当前设备：', 'Device: ', '端末：') + _runtime.manufacturer,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                      if (_actionFailed || _runtime.lastError.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          t(
                            '暂时无法完成操作，请检查通知权限和手机后台设置后重试。',
                            'This action could not finish. Check notification permission and background settings, then try again.',
                            '操作を完了できませんでした。通知権限とバックグラウンド設定を確認して再度お試しください。',
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
