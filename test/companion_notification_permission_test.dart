import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:ryza_chat_mvp/src/companion_notification_permission.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final requests = <List<int>>[];
  var status = PermissionStatus.denied;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    requests.clear();
    status = PermissionStatus.denied;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (call) async {
        if (call.method == 'checkPermissionStatus') return status.index;
        if (call.method == 'requestPermissions') {
          final permissions = List<int>.from(call.arguments as List);
          requests.add(permissions);
          return {
            for (final permission in permissions) permission: status.index,
          };
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('agent_atelier_r/companion_runtime'),
      (_) async => {'notificationsAllowed': status == PermissionStatus.granted},
    );
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('agent_atelier_r/companion_runtime'),
      null,
    );
  });
  test(
    'notification denial prompts once and never asks for phone access',
    () async {
      await requestCompanionNotificationPermissionOnce();
      await requestCompanionNotificationPermissionOnce();
      expect(requests, [
        [Permission.notification.value],
      ]);
    },
  );
  test('existing notification permission needs no dialog', () async {
    status = PermissionStatus.granted;
    await requestCompanionNotificationPermissionOnce();
    expect(requests, isEmpty);
  });
  test('a background startup does not show a permission dialog', () async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await requestCompanionNotificationPermissionOnce();
    expect(requests, isEmpty);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await requestCompanionNotificationPermissionOnce();
    expect(requests, hasLength(1));
  });
  test('permanent denial is left to the explicit settings action', () async {
    status = PermissionStatus.permanentlyDenied;
    await requestCompanionNotificationPermissionOnce();
    expect(requests, isEmpty);
  });
}
