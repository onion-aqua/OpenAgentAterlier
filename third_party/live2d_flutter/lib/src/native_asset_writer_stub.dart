import 'package:flutter/services.dart';

Future<String> writeAssetDirectory({
  required String assetDir,
  required List<String> assetKeys,
  required String tempPath,
  required AssetBundle bundle,
}) {
  throw UnsupportedError('Asset extraction is unavailable on this platform.');
}
