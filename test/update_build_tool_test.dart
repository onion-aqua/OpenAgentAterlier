import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/update/update_build_config.dart';

void main() {
  late String dartExecutable;
  setUpAll(() async {
    final packagesFile = File('.dart_tool/package_config.json').absolute;
    final packages =
        (jsonDecode(await packagesFile.readAsString()) as Map)['packages']
            as List;
    final flutter = packages.cast<Map>().firstWhere(
      (entry) => entry['name'] == 'flutter',
    );
    final sdk = Directory.fromUri(
      packagesFile.uri.resolve(flutter['rootUri'] as String),
    ).parent.parent;
    dartExecutable =
        '${sdk.path}/bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}';
  });
  test(
    'preparation CLI emits only independently decryptable OAA definitions',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'oaa-update-cli-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final input = File('${directory.path}/config.json');
      final output = File('${directory.path}/defines.json');
      const endpoint =
          'https://updates.example.test/openagentatelier/latest.json';
      await input.writeAsString(
        jsonEncode({
          'v': 1,
          'github_latest_url': endpoint,
          'trusted_keys': {
            'oaa-test-key': base64.encode(List<int>.filled(32, 7)),
          },
          'resource_asset_key_ids': ['oaa-test-assets'],
          'release_seq': 1,
          'channel': 'openagentatelier-test',
          'runtime_compat_id': 'openagentatelier-android-bootstrap-v1',
          'resource_api_version': 1,
          'updater_protocol_version': 1,
        }),
      );
      final result = await Process.run(dartExecutable, [
        'run',
        'tool/prepare_update_config.dart',
        '--config-file',
        input.path,
        '--output-file',
        output.path,
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final encoded = await output.readAsString();
      expect(encoded, isNot(contains(endpoint)));
      expect('${result.stdout}${result.stderr}', isNot(contains(endpoint)));
      final definitions = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
      expect(
        definitions.keys,
        unorderedEquals(['OAA_UPDATE_CONFIG_BLOB', 'OAA_UPDATE_CONFIG_KEY']),
      );
      final config = await UpdateBuildConfig.fromProtectedDefines(
        encrypted: definitions[updateConfigBlobDefine] as String,
        key: definitions[updateConfigKeyDefine] as String,
      );
      expect(config.channel, 'openagentatelier-test');
      expect(config.sources!.githubLatest.toString(), endpoint);
    },
  );

  test(
    'preparation rejects duplicate keys without writing or leaking raw JSON',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'oaa-update-invalid-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final input = File('${directory.path}/invalid.json');
      final output = File('${directory.path}/defines.json');
      const endpoint = 'https://private.example.test/should-never-print';
      await input.writeAsString(
        '{"v":1,"v":1,"github_latest_url":"$endpoint"}',
      );
      final result = await Process.run(dartExecutable, [
        'run',
        'tool/prepare_update_config.dart',
        '--config-file',
        input.path,
        '--output-file',
        output.path,
      ]);
      expect(result.exitCode, 1);
      expect(await output.exists(), isFalse);
      expect('${result.stdout}${result.stderr}', isNot(contains(endpoint)));
    },
  );
}
