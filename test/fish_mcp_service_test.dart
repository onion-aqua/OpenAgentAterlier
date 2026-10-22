import 'package:flutter_test/flutter_test.dart';

import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/fish_mcp_service.dart';

void main() {
  test(
    'Fish MCP ignores callbacks addressed to the previous application',
    () async {
      final service = FishMcpService.instance;
      await service.disconnect(clearError: true);

      await service.handleRedirectUri(
        Uri.parse('fishmcp://oauth/callback?error=access_denied'),
      );

      expect(service.state, FishMcpConnectionState.disconnected);
      expect(service.errorMessage, isNull);
    },
  );

  test(
    'Fish MCP accepts its own OAuth callback without a network request',
    () async {
      final service = FishMcpService.instance;
      await service.disconnect(clearError: true);
      expect(
        FishMcpService.callbackUri,
        'agentatelier-fishmcp://oauth/callback',
      );

      await service.handleRedirectUri(
        Uri.parse(FishMcpService.callbackUri)
            .replace(queryParameters: {'error': 'access_denied'}),
      );

      expect(service.state, FishMcpConnectionState.error);
      expect(service.errorMessage, contains('access_denied'));
      await service.disconnect(clearError: true);
    },
  );

  test('Fish MCP ignores a callback with the wrong host or path', () async {
    final service = FishMcpService.instance;
    await service.disconnect(clearError: true);
    final callback = Uri.parse(FishMcpService.callbackUri);

    for (final uri in [
      callback.replace(host: 'other', query: 'error=access_denied'),
      callback.replace(path: '/other', query: 'error=access_denied'),
    ]) {
      await service.handleRedirectUri(uri);
      expect(service.state, FishMcpConnectionState.disconnected);
      expect(service.errorMessage, isNull);
    }
  });

  test('Fish MCP is an OAuth provider and does not require an API key', () {
    expect(TtsProvider.fishAudioMcp.requiresApiKey, isFalse);
    expect(TtsProvider.fishAudioMcp.label, contains('MCP'));
  });

  test('Fish MCP blocks paid generation before tools/list discovery', () async {
    final service = FishMcpService.instance;
    await service.disconnect(clearError: true);
    await expectLater(
      service.synthesize(text: 'こんにちは'),
      throwsA(
        isA<FishMcpException>()
            .having((error) => error.stage, 'stage', 'preflight')
            .having((error) => error.code, 'code', 'not_ready')
            .having((error) => error.generationSubmitted, 'submitted', false),
      ),
    );
  });
}
