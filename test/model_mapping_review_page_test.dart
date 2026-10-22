import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/model_mapping_review_page.dart';
import 'package:ryza_chat_mvp/src/model_mapping_service.dart';
import 'package:ryza_chat_mvp/src/model_performance_mapping.dart';
import 'package:ryza_chat_mvp/src/model_resource_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

ModelResourceCatalog _supportedCatalog() => ModelResourceCatalog(
  format: ModelResourceFormat.spine,
  sourceFingerprint: 'review-fingerprint',
  runtimeVersion: '4.2.43',
  entryFile: 'model.skel',
  resources: const [
    ModelResource(
      id: 'animation:wait',
      kind: ModelResourceKinds.animation,
      name: 'wait',
      native: {'name': 'wait'},
    ),
    ModelResource(
      id: 'animation:hello',
      kind: ModelResourceKinds.animation,
      name: 'hello',
      native: {'name': 'hello'},
    ),
    ModelResource(
      id: 'animation:face_smile',
      kind: ModelResourceKinds.animation,
      name: 'face_smile',
      native: {'name': 'face_smile'},
    ),
    ModelResource(
      id: 'animation:lip',
      kind: ModelResourceKinds.animation,
      name: 'lip',
      native: {
        'name': 'lip',
        'normalizedMouthOpen': true,
        'mouthOpenRange': [0, 1],
      },
    ),
  ],
);

Map<String, Object?> _binding(String target) => {
  'target': target,
  'description': 'direct resource evidence',
  'confidence': 0.95,
  'evidence': 'exact animation name',
};

String _mappingJson(
  ModelResourceCatalog catalog, {
  String actionTarget = 'animation:hello',
}) => jsonEncode({
  'schemaVersion': 1,
  'sourceFingerprint': catalog.sourceFingerprint,
  'format': catalog.format.name,
  'label': 'Reviewed model',
  'idle': 'animation:wait',
  'actions': {'wave': _binding(actionTarget)},
  'expressions': {'happy': _binding('animation:face_smile')},
  'parameters': {'mouthOpen': _binding('animation:lip')},
  'notes': ['Only direct names were mapped.'],
});

Future<AppController> _controller() async {
  final directory = await Directory.systemTemp.createTemp(
    'model_mapping_review_',
  );
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(pathProvider, (_) async => directory.path);
  addTearDown(() async {
    messenger.setMockMethodCallHandler(pathProvider, null);
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  SharedPreferences.setMockInitialValues({
    'active_character_id_v1': 'sophie',
    'ai_enabled': false,
    'fish_tts_enabled': false,
  });
  return AppController.load();
}

FilledButton _confirmButton(WidgetTester tester) => tester.widget<FilledButton>(
  find.byKey(const ValueKey('model-mapping-confirm')),
);

Future<void> _mount(
  WidgetTester tester, {
  required ModelResourceCatalog catalog,
  required AppController controller,
  required ModelMappingService service,
  ValueChanged<ModelPerformanceMapping?>? onResult,
  String? compatibleTemplateLabel,
  ValueChanged<bool>? onPreserveTemplateChanged,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(600, 1800);
  addTearDown(tester.view.reset);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              key: const ValueKey('open-model-mapping-review'),
              onPressed: () async {
                final result = await Navigator.of(context)
                    .push<ModelPerformanceMapping>(
                      MaterialPageRoute(
                        builder: (_) => ModelMappingReviewPage(
                          catalog: catalog,
                          controller: controller,
                          service: service,
                          compatibleTemplateLabel: compatibleTemplateLabel,
                          onPreserveTemplateChanged: onPreserveTemplateChanged,
                        ),
                      ),
                    );
                onResult?.call(result);
              },
              child: const Text('Open review'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-model-mapping-review')));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'confirm stays disabled until callback transport succeeds and invalid edits disable it',
    (tester) async {
      final catalog = _supportedCatalog();
      final controller = (await tester.runAsync(_controller))!;
      final response = Completer<String>();
      ModelPerformanceMapping? routeResult;
      var calls = 0;
      late String requestInput;
      final service = ModelMappingService(
        transport: (_, input) {
          calls++;
          requestInput = input;
          return response.future;
        },
      );
      await _mount(
        tester,
        catalog: catalog,
        controller: controller,
        service: service,
        onResult: (value) => routeResult = value,
      );

      expect(controller.aiEnabled, isFalse);
      expect(_confirmButton(tester).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('model-mapping-analyze')));
      await tester.pump();
      expect(calls, 1);
      expect(jsonDecode(requestInput), isA<Map>());
      expect(find.text('正在分析资源…'), findsOneWidget);
      expect(_confirmButton(tester).onPressed, isNull);

      response.complete(_mappingJson(catalog));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Reviewed model'), findsOneWidget);
      expect(_confirmButton(tester).onPressed, isNotNull);

      final expansion = find.text('编辑映射 JSON');
      await tester.ensureVisible(expansion);
      await tester.tap(expansion);
      await tester.pumpAndSettle();
      final editor = find.byKey(const ValueKey('model-mapping-editor'));
      await tester.enterText(
        editor,
        _mappingJson(catalog, actionTarget: 'animation:missing'),
      );
      await tester.pump();
      expect(find.textContaining('unknown resource'), findsOneWidget);
      expect(_confirmButton(tester).onPressed, isNull);

      expect(editor, findsOneWidget);
      await tester.enterText(editor, _mappingJson(catalog));
      await tester.pump();
      expect(find.byKey(const ValueKey('model-mapping-error')), findsNothing);
      expect(_confirmButton(tester).onPressed, isNotNull);
      expect(calls, 1, reason: 'editing must not make another model request');
      await tester.tap(find.byKey(const ValueKey('model-mapping-confirm')));
      await tester.pumpAndSettle();
      expect(routeResult, isNotNull);
      expect(routeResult!.label, 'Reviewed model');
    },
  );

  final mano = File(
    r'C:\Users\cheny\Documents\Codex\2026-10-21\https-github-com-sallyn0225-eidolon-sc\outputs\mano-1030010010.zip',
  );
  testWidgets(
    'unsupported Mano analysis can be copied but never confirmed for import',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final catalog = await inspectModelResources(
        mano.readAsBytesSync(),
        format: ModelResourceFormat.spine,
      );
      debugDefaultTargetPlatformOverride = null;
      final controller = (await tester.runAsync(_controller))!;
      var calls = 0;
      final service = ModelMappingService(
        transport: (_, _) async {
          calls++;
          return jsonEncode({
            'schemaVersion': 1,
            'sourceFingerprint': catalog.sourceFingerprint,
            'format': 'spine',
            'label': 'Mano 3.6 review',
            'idle': 'animation:wait',
            'actions': {},
            'expressions': {},
            'parameters': {},
            'notes': ['Conversion to 4.2 is still required.'],
          });
        },
      );
      String? copied;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await _mount(
        tester,
        catalog: catalog,
        controller: controller,
        service: service,
      );

      expect(catalog.runtimeSupported, isFalse);
      await tester.tap(find.byKey(const ValueKey('model-mapping-analyze')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, 1);
      expect(_confirmButton(tester).onPressed, isNull);
      expect(find.textContaining('完成对应渲染适配后才能导入'), findsOneWidget);

      final copy = find.widgetWithText(TextButton, '复制映射');
      await tester.ensureVisible(copy);
      expect(tester.widget<TextButton>(copy).onPressed, isNotNull);
      await tester.tap(copy);
      await tester.pump();
      expect(copied, isNotNull);
      expect(copied, contains(catalog.sourceFingerprint));
      expect(copied, contains('Mano 3.6 review'));
    },
    skip: !mano.existsSync(),
  );

  testWidgets('template choice is explicit and back cancels without result', (
    tester,
  ) async {
    final catalog = _supportedCatalog();
    final controller = (await tester.runAsync(_controller))!;
    final service = ModelMappingService(
      transport: (_, _) async => _mappingJson(catalog),
    );
    ModelPerformanceMapping? routeResult;
    var routeCompleted = false;
    final preserved = <bool>[];
    await _mount(
      tester,
      catalog: catalog,
      controller: controller,
      service: service,
      compatibleTemplateLabel: '常服·坐姿',
      onPreserveTemplateChanged: preserved.add,
      onResult: (value) {
        routeCompleted = true;
        routeResult = value;
      },
    );

    await tester.tap(find.byKey(const ValueKey('model-mapping-analyze')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final checkbox = find.byType(CheckboxListTile);
    await tester.ensureVisible(checkbox);
    expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
    await tester.tap(checkbox);
    await tester.pump();
    expect(preserved, [false]);
    expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(routeCompleted, isTrue);
    expect(routeResult, isNull);
  });
}
