import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

typedef AgentToolExecutor = Future<String> Function(
  String name,
  Map<String, dynamic> arguments,
);

class DeviceAgentTools {
  const DeviceAgentTools();

  static const _channel = MethodChannel('ryza_chat/device_tools');

  Future<String> execute(String name, Map<String, dynamic> arguments) async {
    return switch (name) {
      'get_current_location' => _currentLocation(),
      'list_launchable_apps' => _launchableApps(arguments),
      'get_local_datetime' => _localDateTime(),
      _ => '工具调用失败：设备不支持工具 $name。',
    };
  }

  Future<String> _currentLocation() async {
    if (!Platform.isAndroid) {
      return '位置工具当前仅支持 Android。';
    }
    var status = await Permission.locationWhenInUse.status;
    if (!status.isGranted) {
      status = await Permission.locationWhenInUse.request();
    }
    if (!status.isGranted) {
      return status.isPermanentlyDenied
          ? '定位权限被永久拒绝。请提示用户在系统设置中为应用开启“使用期间允许定位”；不要猜测用户位置。'
          : '用户未授予定位权限。不要猜测用户位置，可询问用户所在城市。';
    }
    try {
      final value = await _channel.invokeMapMethod<String, dynamic>(
        'getCurrentLocation',
      );
      if (value == null) return '暂时无法取得当前位置，请稍后重试或询问用户所在城市。';
      return jsonEncode({
        'latitude': value['latitude'],
        'longitude': value['longitude'],
        'accuracyMeters': value['accuracyMeters'],
        'provider': value['provider'],
        'capturedAt': value['capturedAt'],
        'privacyNote': '仅用于本次工具调用，应用不会将位置写入长期记忆。',
      });
    } on PlatformException catch (error) {
      return '定位失败：${error.message ?? error.code}。可询问用户所在城市后继续。';
    }
  }

  Future<String> _launchableApps(Map<String, dynamic> arguments) async {
    if (!Platform.isAndroid) {
      return '应用列表工具当前仅支持 Android。';
    }
    try {
      final raw = await _channel.invokeListMethod<dynamic>(
        'listLaunchableApps',
      );
      final query = (arguments['query'] as String? ?? '').trim().toLowerCase();
      final requestedLimit = arguments['limit'] as num?;
      final limit = (requestedLimit?.toInt() ?? 60).clamp(1, 80);
      final apps = (raw ?? const <dynamic>[])
          .whereType<Map<dynamic, dynamic>>()
          .map(
            (item) => {
              'name': item['name']?.toString() ?? '',
              'packageName': item['packageName']?.toString() ?? '',
            },
          )
          .where(
            (app) =>
                query.isEmpty ||
                app['name']!.toLowerCase().contains(query) ||
                app['packageName']!.toLowerCase().contains(query),
          )
          .take(limit)
          .toList(growable: false);
      return jsonEncode({
        'apps': apps,
        'returned': apps.length,
        'scope': '仅列出具有桌面启动入口的应用，不读取使用记录或应用数据。',
      });
    } on PlatformException catch (error) {
      return '读取可启动应用失败：${error.message ?? error.code}。';
    }
  }

  String _localDateTime() {
    final now = DateTime.now();
    return jsonEncode({
      'localDateTime': now.toIso8601String(),
      'timeZoneName': now.timeZoneName,
      'timeZoneOffsetMinutes': now.timeZoneOffset.inMinutes,
    });
  }
}
