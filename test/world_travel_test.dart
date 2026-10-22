import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/world_map_screen.dart';
import 'package:ryza_chat_mvp/src/world_travel_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'world travel catalog resolves localized reservoir destination',
    () async {
      final catalog = await WorldTravelCatalog.load();
      final destination = catalog.byStageId('stage_01_001_01');

      expect(destination, isNotNull);
      expect(destination!.fieldId, 'field_01_001');
      expect(destination.localizedStageName(AppLanguage.chinese), '尖塔的蓄水池');
    },
  );

  test('agent map tools validate and apply a real destination', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    controller.setAgentEnabled(true);

    final inspection = jsonDecode(
      controller.queryContextTool('inspect_map_locations', {'query': '尖塔'}),
    ) as Map<String, dynamic>;
    expect(inspection['ok'], isTrue);
    expect(
      (inspection['destinations'] as List<dynamic>).any(
        (item) => item['stage_id'] == 'stage_01_001_01',
      ),
      isTrue,
    );

    final invalid = jsonDecode(
      controller.queryContextTool('travel_to_stage', {
        'stage_id': 'stage_not_real',
      }),
    ) as Map<String, dynamic>;
    expect(invalid['ok'], isFalse);

    final traveled = jsonDecode(
      controller.queryContextTool('travel_to_stage', {
        'stage_id': 'stage_01_001_01',
      }),
    ) as Map<String, dynamic>;
    expect(traveled['ok'], isTrue);
    expect(traveled['changed'], isTrue);
    expect(controller.selectedStageId, 'stage_01_001_01');
    expect(controller.selectedStageName, '尖塔的蓄水池');
    expect(controller.messages.last.text, contains('已抵达'));
    controller.dispose();
  });

  test('small-map stage hit test picks the nearest landmark', () {
    const reservoir = Offset(120, 160);
    const lighthouse = Offset(190, 110);

    expect(
      nearestStageIndexWithinRadius(
        positions: const [reservoir, lighthouse],
        point: const Offset(126, 157),
      ),
      0,
    );
    expect(
      nearestStageIndexWithinRadius(
        positions: const [reservoir, lighthouse],
        point: const Offset(300, 300),
      ),
      isNull,
    );
  });
}
