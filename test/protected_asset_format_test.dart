import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/protected_asset_format.dart';

void main() {
  final key = Uint8List.fromList(List<int>.generate(32, (index) => index));

  test('protected asset pack decrypts only with its key and pack id', () async {
    final files = <String, Uint8List>{
      'assets/character/test/test.atlas': Uint8List.fromList(
        utf8.encode('texture.png\nsize: 8,8'),
      ),
      'assets/character/test/texture.png': Uint8List.fromList(
        List<int>.generate(64, (index) => index),
      ),
    };
    final encrypted = await encryptProtectedAssetFiles(
      files: files,
      key: key,
      packId: 'character/test',
      nonce: List<int>.generate(12, (index) => index + 1),
    );

    expect(
      utf8.decode(encrypted, allowMalformed: true),
      isNot(contains('texture.png')),
    );
    final restored = await decryptProtectedAssetFiles(
      encrypted: encrypted,
      key: key,
      packId: 'character/test',
    );
    expect(restored.keys, files.keys);
    expect(restored['assets/character/test/test.atlas'], files.values.first);
    for (final bytes in restored.values) {
      expect(bytes.offsetInBytes, 0);
      expect(bytes.buffer.lengthInBytes, bytes.lengthInBytes);
    }

    await expectLater(
      decryptProtectedAssetFiles(
        encrypted: encrypted,
        key: Uint8List(32),
        packId: 'character/test',
      ),
      throwsA(isA<ProtectedAssetException>()),
    );
    await expectLater(
      decryptProtectedAssetFiles(
        encrypted: encrypted,
        key: key,
        packId: 'preview/test',
      ),
      throwsA(isA<ProtectedAssetException>()),
    );
  });

  test('protected asset key accepts URL-safe Base64 without padding', () {
    const encoded = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';
    expect(decodeProtectedAssetKey(encoded), key);
    expect(
      () => decodeProtectedAssetKey('short'),
      throwsA(isA<ProtectedAssetException>()),
    );
  });
}
