import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'android_companion_runtime.dart';
import 'runtime_log.dart';

/// Ask once after the app has a visible page, never on a background restart.
Future<void> requestCompanionNotificationPermissionOnce() async {
  final runtime = AndroidCompanionRuntime.instance;
  if (!runtime.enabled || runtime.stopRequested) return;
  if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
    return;
  }
  try {
    final preferences = await SharedPreferences.getInstance();
    const key = 'companion_notification_permission_prompted_v1';
    if (preferences.getBool(key) == true) return;
    final status = await Permission.notification.status;
    await preferences.setBool(key, true);
    if (status.isDenied) await Permission.notification.request();
    await runtime.refresh();
  } on Object catch (error) {
    RuntimeLog.instance.warning('Audio', '陪伴通知授权检查未完成：${error.runtimeType}');
  }
}
