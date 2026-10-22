import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/protected_character_assets.dart';
import 'package:ryza_chat_mvp/src/spine36_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only exact legacy major/minor versions select the 3.6 player', () {
    expect(isSpine36('3.6.53'), isTrue);
    for (final version in ['3.60.1', '3.6x', '4.2.43', '3.8.99']) {
      expect(isSpine36(version), isFalse);
    }
  });

  test(
    'renamed imports resolve the original atlas texture and byte slices',
    () async {
      Uint8List text(String value) => Uint8List.fromList(utf8.encode(value));
      final texture = Uint8List.fromList([137, 80, 78, 71]);
      final model = await Spine36Model.fromBundle(
        ProtectedCharacterAssetBundle({
          'model/local_123.json': text('{"skeleton":{"spine":"3.6.53"}}'),
          'model/local_123.atlas': text('\ndata.png\nsize: 1024,1024\n'),
          'model/data.png': texture,
        }),
        skeleton: 'model/local_123.json',
        atlas: 'model/local_123.atlas',
      );
      expect(model.texture, texture);
      expect(
        utf8.decode(model.payload['atlas'] as Uint8List),
        startsWith('texture.png\n'),
      );
      expect(utf8.decode(model.atlas), contains('data.png'));
      expect(model.payload, same(model.payload));
    },
  );

  test(
    'native validation failures propagate instead of accepting an import',
    () async {
      const channel = MethodChannel('agentatelier/spine36');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: 'spine36_load_failed',
          message: 'Invalid mesh',
        );
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final model = Spine36Model(
        Uint8List.fromList(utf8.encode('{"skeleton":{"spine":"3.6.53"}}')),
        Uint8List.fromList(utf8.encode('data.png\nsize: 1,1\n')),
        Uint8List(0),
      );
      await expectLater(model.validate(), throwsA(isA<PlatformException>()));
    },
  );
}
