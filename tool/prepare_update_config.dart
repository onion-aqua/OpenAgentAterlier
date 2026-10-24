import 'dart:convert';
import 'dart:io';

import 'package:ryza_chat_mvp/src/update/strict_json.dart';
import 'package:ryza_chat_mvp/src/update/update_build_config.dart';

/// Prepares build definitions only. It never contacts an update service.
Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && arguments.single == '--help') {
    stdout.writeln(
      'dart run tool/prepare_update_config.dart '
      '--config-file <local.json> --output-file <defines.json>',
    );
    return;
  }
  try {
    final options = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      final name = arguments[index];
      if (!const {'--config-file', '--output-file'}.contains(name) ||
          index + 1 >= arguments.length ||
          options.containsKey(name)) {
        throw const FormatException();
      }
      options[name] = arguments[index + 1];
    }
    if (options.length != 2) throw const FormatException();
    final input = File(options['--config-file']!);
    final output = File(options['--output-file']!);
    if (input.absolute.path == output.absolute.path ||
        await input.length() > 32768) {
      throw const FormatException();
    }
    final config = decodeStrictUpdateJson(await input.readAsString());
    final definitions = await protectUpdateBuildConfiguration(config);
    await output.parent.create(recursive: true);
    await output.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(definitions)}\n',
      flush: true,
    );
    stdout.writeln(
      'OpenAgentAtelier update definitions prepared. No endpoint was contacted.',
    );
  } on Object {
    stderr.writeln(
      'Update configuration preparation failed. Check the local JSON, '
      'HTTPS endpoints and public verification keys. No configuration value was printed.',
    );
    exitCode = 1;
  }
}
