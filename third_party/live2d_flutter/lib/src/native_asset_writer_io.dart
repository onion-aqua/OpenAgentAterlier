import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

Future<String> writeAssetDirectory({
  required String assetDir,
  required List<String> assetKeys,
  required String tempPath,
  required AssetBundle bundle,
}) async {
  final key = base64UrlEncode(utf8.encode(assetDir)).replaceAll('=', '');
  final outDir = Directory('$tempPath/flutter_live2d_models/$key/');
  final marker = File('${outDir.path}.ready');

  if (outDir.existsSync() && marker.existsSync()) {
    return _withTrailingSlash(outDir.path);
  }
  if (outDir.existsSync()) {
    await outDir.delete(recursive: true);
  }
  await outDir.create(recursive: true);

  for (final assetKey in assetKeys) {
    final relativePath = assetKey.substring(assetDir.length);
    final outFile = File('${outDir.path}$relativePath');
    await outFile.parent.create(recursive: true);
    final data = await bundle.load(assetKey);
    await outFile.writeAsBytes(data.buffer.asUint8List(), flush: true);
  }

  await marker.writeAsString('ok', flush: true);
  return _withTrailingSlash(outDir.path);
}

String _withTrailingSlash(String path) => path.endsWith('/') ? path : '$path/';
