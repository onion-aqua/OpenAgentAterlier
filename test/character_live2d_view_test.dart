import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_flutter/live2d_flutter.dart';
import 'package:ryza_chat_mvp/src/character_expression.dart';
import 'package:ryza_chat_mvp/src/character_live2d_view.dart';
import 'package:ryza_chat_mvp/src/live2d_model_descriptor.dart';

class _Call {
  const _Call(this.method, [this.arguments = const {}]);
  final String method;
  final Map<String, Object?> arguments;
}

/// Exercises the published controller and platform-view attachment, while the
/// runtime boundary is a recording fake. No Cubism native code or TTS runs.
class _FakeLive2dPlatform extends FlutterLive2dPlatform {
  final calls = <_Call>[];
  final loadGates = <String, Completer<bool>>{};
  Completer<void>? expressionGate;
  Completer<void>? parameterGate;
  String? activeModel;

  List<_Call> named(String method) =>
      calls.where((call) => call.method == method).toList();

  @override
  Future<bool> loadModel({
    required int viewId,
    required String modelDir,
    required String modelFileName,
  }) async {
    calls.add(
      _Call('load', {
        'viewId': viewId,
        'directory': modelDir,
        'file': modelFileName,
      }),
    );
    final gate = loadGates[modelFileName];
    final accepted = gate == null ? true : await gate.future;
    if (accepted) activeModel = modelFileName;
    return accepted;
  }

  @override
  Future<void> unloadModel({required int viewId}) async {
    calls.add(_Call('unload', {'viewId': viewId}));
    activeModel = null;
  }

  @override
  Future<void> setRenderingPaused({
    required int viewId,
    required bool paused,
  }) async {
    calls.add(_Call('pause', {'paused': paused}));
  }

  @override
  Future<void> setIdleMotion({
    required int viewId,
    required String group,
    int index = 0,
  }) async {
    calls.add(_Call('idle', {'group': group, 'index': index}));
  }

  @override
  Future<void> startMotion({
    required int viewId,
    required String group,
    required int index,
    int priority = 2,
  }) async {
    calls.add(
      _Call('motion', {
        'group': group,
        'index': index,
        'priority': priority,
        'model': activeModel,
      }),
    );
  }

  @override
  Future<void> setExpression({required int viewId, required int index}) async {
    calls.add(_Call('expression', {'index': index, 'model': activeModel}));
    await expressionGate?.future;
  }

  @override
  Future<void> setParameter({
    required int viewId,
    required String parameterId,
    required double value,
  }) async {
    calls.add(_Call('parameter', {'id': parameterId, 'value': value}));
    await parameterGate?.future;
  }
}

Map<String, Object?> _model({String motionGroup = 'Gesture'}) => {
  'Version': 3,
  'FileReferences': {
    'Moc': 'model.moc3',
    'Textures': ['texture.png'],
    'Motions': {
      motionGroup: [
        {'File': 'motions/first.motion3.json'},
        {'File': 'motions/second.motion3.json'},
      ],
    },
    'Expressions': [
      {'Name': 'NeutralFace', 'File': 'expressions/neutral.exp3.json'},
      {'Name': 'JoyFace', 'File': 'expressions/joy.exp3.json'},
    ],
  },
};

Map<String, Object?> _manifest({String motionGroup = 'Gesture'}) => {
  'actions': {
    'wave': {
      'group': motionGroup,
      'index': 1,
      'description': 'A real greeting wave',
    },
  },
  'expressions': {
    'happy': {'name': 'JoyFace'},
    'neutral': {'name': 'NeutralFace'},
  },
  'parameters': {'mouthOpen': 'CustomMouth'},
};

Live2DModelDescriptor _descriptor({String motionGroup = 'Gesture'}) =>
    Live2DModelDescriptor.fromMaps(
      _model(motionGroup: motionGroup),
      manifest: _manifest(motionGroup: motionGroup),
    );

Widget _app(CharacterLive2dView view) =>
    MaterialApp(home: SizedBox(width: 300, height: 600, child: view));

Future<void> _waitForIo(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump();
    if (condition()) return;
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    });
  }
  fail('The expected asynchronous Live2D operation did not complete.');
}

void _testWidgets(String description, WidgetTesterCallback callback) =>
    testWidgets(
      description,
      callback,
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FlutterLive2dPlatform previousPlatform;
  late _FakeLive2dPlatform platform;
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('aar_live2d_widget_');
    await File('${directory.path}/sample.model3.json')
        .writeAsString(jsonEncode(_model()));
    await File('${directory.path}/performance.manifest.json')
        .writeAsString(jsonEncode(_manifest()));
    previousPlatform = FlutterLive2dPlatform.instance;
    platform = _FakeLive2dPlatform();
    FlutterLive2dPlatform.instance = platform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform_views,
          (_) async => null,
        );
  });

  tearDown(() async {
    FlutterLive2dPlatform.instance = previousPlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    await directory.delete(recursive: true);
  });

  _testWidgets(
    'loads filesystem model and manifest before resolving performance',
    (tester) async {
      final descriptors = <Live2DModelDescriptor?>[];
      var ready = 0;
      await tester.pumpWidget(
        _app(
          CharacterLive2dView(
            modelDirectory: directory.path,
            modelFileName: 'sample.model3.json',
            manifestAsset: 'performance.manifest.json',
            expression: CharacterExpression.happy,
            action: 'wave',
            onDescriptor: descriptors.add,
            onReady: () => ready++,
          ),
        ),
      );
      await _waitForIo(tester, () => platform.named('motion').isNotEmpty);

      expect(ready, 1);
      expect(descriptors.single!.resolveAction('wave')!.index, 1);
      expect(
        platform.named('load').single.arguments['directory'],
        '${directory.path}/',
      );
      expect(
        platform.named('load').single.arguments['file'],
        'sample.model3.json',
      );
      expect(platform.named('expression').single.arguments['index'], 1);
      expect(
        platform.named('motion').single.arguments,
        containsPair('group', 'Gesture'),
      );
      expect(
        platform.named('motion').single.arguments,
        containsPair('index', 1),
      );
      expect(
        platform.named('motion').single.arguments,
        containsPair('priority', 2),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Live2D 模型加载失败'), findsNothing);
    },
  );

  _testWidgets('mapped idle is configured before foreground performance', (
    tester,
  ) async {
    final descriptor = Live2DModelDescriptor.fromMaps(
      _model(),
      manifest: {
        ..._manifest(),
        'idle': {'group': 'Gesture', 'index': 0},
      },
    );
    Widget view(int nonce) => _app(
      CharacterLive2dView(
        modelDirectory: directory.path,
        modelFileName: 'sample.model3.json',
        descriptor: descriptor,
        action: 'wave',
        actionNonce: nonce,
      ),
    );
    await tester.pumpWidget(view(1));
    await _waitForIo(tester, () => platform.named('motion').isNotEmpty);
    expect(platform.named('idle').single.arguments, {
      'group': 'Gesture',
      'index': 0,
    });
    final methods = platform.calls.map((call) => call.method).toList();
    expect(methods.indexOf('idle'), lessThan(methods.indexOf('motion')));
    await tester.pumpWidget(view(2));
    await tester.pump();
    expect(platform.named('idle'), hasLength(1));
    expect(platform.named('motion'), hasLength(2));
    expect(tester.takeException(), isNull);
  });

  _testWidgets('repeats an exact action only when its nonce changes', (
    tester,
  ) async {
    final descriptor = _descriptor();
    Widget view(int nonce) => _app(
      CharacterLive2dView(
        modelDirectory: directory.path,
        modelFileName: 'sample.model3.json',
        descriptor: descriptor,
        action: 'wave',
        actionNonce: nonce,
      ),
    );
    await tester.pumpWidget(view(1));
    await _waitForIo(tester, () => platform.named('motion').isNotEmpty);
    await tester.pumpWidget(view(1));
    await tester.pump();
    expect(platform.named('motion'), hasLength(1));
    await tester.pumpWidget(view(2));
    await tester.pump();
    expect(platform.named('motion'), hasLength(2));
    expect(platform.named('load'), hasLength(1));
  });

  _testWidgets(
    'unknown actions do not play and missing expressions resolve neutral',
    (tester) async {
      await tester.pumpWidget(
        _app(
          CharacterLive2dView(
            modelDirectory: directory.path,
            modelFileName: 'sample.model3.json',
            descriptor: _descriptor(),
            action: 'unsupported_hug',
            expression: CharacterExpression.angry,
          ),
        ),
      );
      await _waitForIo(tester, () => platform.named('expression').isNotEmpty);
      expect(platform.named('motion'), isEmpty);
      expect(platform.named('expression').single.arguments['index'], 0);
    },
  );

  _testWidgets(
    'pause controls rendering and silences the configured mouth envelope',
    (tester) async {
      final descriptor = _descriptor();
      Widget view(bool paused, bool speaking) => _app(
        CharacterLive2dView(
          modelDirectory: directory.path,
          modelFileName: 'sample.model3.json',
          descriptor: descriptor,
          paused: paused,
          speaking: speaking,
          speechEnergyProvider: () => 0.65,
        ),
      );
      await tester.pumpWidget(view(false, true));
      await _waitForIo(tester, () => platform.named('parameter').isNotEmpty);
      expect(platform.named('parameter').last.arguments, {
        'id': 'CustomMouth',
        'value': 0.65,
      });

      await tester.pumpWidget(view(true, true));
      await tester.pump(const Duration(milliseconds: 100));
      expect(platform.named('pause').last.arguments['paused'], isTrue);
      expect(platform.named('parameter').last.arguments['value'], 0.0);
      await tester.pumpWidget(view(false, false));
      await tester.pump();
      expect(platform.named('pause').last.arguments['paused'], isFalse);
      expect(platform.named('parameter').last.arguments['value'], 0.0);
      final count = platform.named('parameter').length;
      await tester.pump(const Duration(milliseconds: 200));
      expect(platform.named('parameter'), hasLength(count));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  _testWidgets(
    'speech stop closes the mouth after an outstanding sample completes',
    (tester) async {
      final gate = Completer<void>();
      platform.parameterGate = gate;
      final descriptor = _descriptor();
      Widget view(bool speaking) => _app(
        CharacterLive2dView(
          modelDirectory: directory.path,
          modelFileName: 'sample.model3.json',
          descriptor: descriptor,
          speaking: speaking,
          speechEnergy: 0.7,
        ),
      );
      await tester.pumpWidget(view(true));
      await _waitForIo(tester, () => platform.named('parameter').isNotEmpty);
      expect(platform.named('parameter').single.arguments['value'], 0.7);
      await tester.pumpWidget(view(false));
      gate.complete();
      await _waitForIo(tester, () => platform.named('parameter').length >= 2);
      expect(platform.named('parameter').last.arguments['value'], 0.0);
      final count = platform.named('parameter').length;
      await tester.pump(const Duration(milliseconds: 200));
      expect(platform.named('parameter'), hasLength(count));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  _testWidgets(
    'an obsolete expression command cannot dispatch its following motion',
    (tester) async {
      final gate = Completer<void>();
      platform.expressionGate = gate;
      Widget view(String file, String group) => _app(
        CharacterLive2dView(
          modelDirectory: directory.path,
          modelFileName: file,
          descriptor: _descriptor(motionGroup: group),
          action: 'wave',
          expression: CharacterExpression.happy,
        ),
      );
      await tester.pumpWidget(view('first.model3.json', 'First'));
      await _waitForIo(tester, () => platform.named('expression').isNotEmpty);
      await tester.pumpWidget(view('second.model3.json', 'Second'));
      gate.complete();
      await _waitForIo(tester, () => platform.named('motion').isNotEmpty);
      expect(platform.named('motion').single.arguments['group'], 'Second');
      expect(
        platform.named('motion').single.arguments['model'],
        'second.model3.json',
      );
      expect(tester.takeException(), isNull);
    },
  );

  _testWidgets('a failed native model load reports a visible error', (
    tester,
  ) async {
    final gate = Completer<bool>();
    platform.loadGates['sample.model3.json'] = gate;
    final failures = <Object>[];
    await tester.pumpWidget(
      _app(
        CharacterLive2dView(
          modelDirectory: directory.path,
          modelFileName: 'sample.model3.json',
          descriptor: _descriptor(),
          onLoadFailed: failures.add,
        ),
      ),
    );
    await _waitForIo(tester, () => platform.named('load').isNotEmpty);
    gate.complete(false);
    await tester.pump();
    expect(failures, hasLength(1));
    expect(find.text('Live2D 模型加载失败'), findsOneWidget);
    expect(platform.named('motion'), isEmpty);
  });

  _testWidgets(
    'disposing an in-flight native load cannot invoke ready or performance',
    (tester) async {
      final gate = Completer<bool>();
      platform.loadGates['sample.model3.json'] = gate;
      var ready = 0;
      final failures = <Object>[];
      await tester.pumpWidget(
        _app(
          CharacterLive2dView(
            modelDirectory: directory.path,
            modelFileName: 'sample.model3.json',
            descriptor: _descriptor(),
            action: 'wave',
            onReady: () => ready++,
            onLoadFailed: failures.add,
          ),
        ),
      );
      await _waitForIo(tester, () => platform.named('load').isNotEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      gate.complete(true);
      await tester.pump();
      expect(ready, 0);
      expect(failures, isEmpty);
      expect(platform.named('motion'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  _testWidgets(
    'a superseded native load cannot replace the newly selected model',
    (tester) async {
      final first = Completer<bool>();
      platform.loadGates['first.model3.json'] = first;
      var firstReady = 0;
      var secondReady = 0;
      Widget view(String file, VoidCallback onReady) => _app(
        CharacterLive2dView(
          modelDirectory: directory.path,
          modelFileName: file,
          descriptor: _descriptor(),
          action: 'wave',
          onReady: onReady,
        ),
      );
      await tester.pumpWidget(view('first.model3.json', () => firstReady++));
      await _waitForIo(tester, () => platform.named('load').isNotEmpty);
      await tester.pumpWidget(view('second.model3.json', () => secondReady++));
      await tester.pump();
      first.complete(true);
      await _waitForIo(tester, () => secondReady == 1);
      expect(firstReady, 0);
      expect(platform.activeModel, 'second.model3.json');
      expect(
        platform
            .named('motion')
            .every((call) => call.arguments['model'] == 'second.model3.json'),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  _testWidgets(
    'an obsolete descriptor read cannot publish to the replacement model',
    (tester) async {
      final source = Completer<ByteData?>();
      final descriptors = <Live2DModelDescriptor?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', (message) {
            final key = utf8.decode(
              message!.buffer.asUint8List(
                message.offsetInBytes,
                message.lengthInBytes,
              ),
            );
            if (key == 'assets/obsolete/model.model3.json') {
              return source.future;
            }
            return Future<ByteData?>.value(null);
          });
      await tester.pumpWidget(
        _app(
          CharacterLive2dView(
            modelDirectory: 'assets/obsolete',
            modelFileName: 'model.model3.json',
            onDescriptor: descriptors.add,
          ),
        ),
      );
      await tester.pump();
      final next = _descriptor(motionGroup: 'Replacement');
      await tester.pumpWidget(
        _app(
          CharacterLive2dView(
            modelDirectory: directory.path,
            modelFileName: 'sample.model3.json',
            descriptor: next,
            onDescriptor: descriptors.add,
          ),
        ),
      );
      await _waitForIo(tester, () => platform.named('load').isNotEmpty);
      source.complete(
        ByteData.sublistView(
          Uint8List.fromList(
            utf8.encode(jsonEncode(_model(motionGroup: 'Obsolete'))),
          ),
        ),
      );
      await tester.pump();
      expect(descriptors, [next]);
      expect(tester.takeException(), isNull);
    },
  );

  _testWidgets(
    'an obsolete descriptor read after disposal cannot publish callbacks',
    (tester) async {
      final source = Completer<ByteData?>();
      final descriptors = <Live2DModelDescriptor?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', (_) => source.future);
      await tester.pumpWidget(
        _app(
          CharacterLive2dView(
            modelDirectory: 'assets/disposed',
            modelFileName: 'model.model3.json',
            onDescriptor: descriptors.add,
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      source.complete(
        ByteData.sublistView(
          Uint8List.fromList(utf8.encode(jsonEncode(_model()))),
        ),
      );
      await tester.pump();
      expect(descriptors, isEmpty);
      expect(platform.named('load'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
