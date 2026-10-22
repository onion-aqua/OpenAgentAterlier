import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_expression.dart';
import 'package:ryza_chat_mvp/src/character_performance.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';

void main() {
  test('every runtime action has a prompt semantic description', () {
    expect(
      CharacterPerformancePromptContext.actionDescriptions.keys.toSet(),
      CharacterAction.values.map((action) => action.name).toSet(),
    );
  });

  test('action tags round-trip and unknown tags fail closed to none', () {
    for (final action in CharacterAction.values) {
      expect(characterActionFromTag(' ${action.name.toUpperCase()} '), action);
    }
    expect(characterActionFromTag('grp_fg_023'), CharacterAction.none);
    expect(characterMotionGroupIdFromTag('grp_fg_023'), 'grp_fg_023');
    expect(characterActionFromTag('cross_your_arms'), CharacterAction.none);
    expect(characterActionFromTag(''), CharacterAction.none);
  });

  test('face tags round-trip and unknown tags fail closed to neutral', () {
    for (final expression in CharacterExpression.values) {
      expect(
        characterExpressionFromTag(' ${expression.name.toUpperCase()} '),
        expression,
      );
    }
    expect(characterExpressionFromTag('face_999'), CharacterExpression.neutral);
  });

  test('ready performance context exposes only its real playable actions', () {
    final context = CharacterPerformancePromptContext(
      appearanceId: 'seated_01',
      posture: 'seated',
      revision: 7,
      resourcesReady: true,
      playableActionDescriptions: const {
        'think': '左手靠近下巴，短暂思考姿态。',
        'wave': '右手轻摆。',
      },
    );
    final data = context.toPromptData();
    final actions = data['actions']! as Map<String, String>;

    expect(data['status'], 'ready');
    expect(data['appearanceId'], 'seated_01');
    expect(data['posture'], 'seated');
    expect(data['revision'], 7);
    expect(actions.keys, containsAll(['think', 'wave', 'none']));
    expect(actions.keys, isNot(contains('explain')));
    expect(
      actions['none'],
      CharacterPerformancePromptContext.noActionDescription,
    );
  });

  test('capability snapshots accept verified motion group keys', () {
    final context = CharacterPerformancePromptContext(
      appearanceId: 'seated_01',
      posture: 'seated',
      revision: 1,
      resourcesReady: true,
      playableActionDescriptions: const {},
      playableMotionGroupDescriptions: const {'grp_fg_023': '双手抱臂组合。'},
    );
    expect(
      (context.toPromptData()['motionGroups']!
          as Map<String, String>)['grp_fg_023'],
      '双手抱臂组合。',
    );
    expect(
      () => CharacterPerformancePromptContext(
        appearanceId: 'seated_01',
        posture: 'seated',
        revision: 1,
        resourcesReady: true,
        playableActionDescriptions: const {},
        playableMotionGroupDescriptions: const {'motion_A_001_idle': '非法'},
      ),
      throwsArgumentError,
    );
  });

  test('not-ready snapshots advertise none only', () {
    final context = CharacterPerformancePromptContext(
      appearanceId: 'seated_01',
      posture: 'seated',
      revision: 3,
      resourcesReady: false,
      playableActionDescriptions: const {},
    );
    final data = context.toPromptData();
    final actions = data['actions']! as Map<String, String>;

    expect(data['status'], 'not_ready');
    expect(actions.keys, ['none']);
  });

  test(
    'model prompt includes runtime capability contract when supplied',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      final prompt = controller.buildCharacterPrompt(
        performanceContext: CharacterPerformancePromptContext(
          appearanceId: controller.selectedCharacterAppearanceId,
          posture: 'seated',
          revision: 12,
          resourcesReady: true,
          playableActionDescriptions: const {
            'think': '短暂思考姿态。',
            'invite': '向用户伸手邀请。',
          },
          playableMotionGroupDescriptions: const {'grp_b_03': '双手叉腰。'},
        ),
      );

      expect(prompt, contains('status=ready'));
      expect(prompt, contains('短暂思考姿态。'));
      expect(prompt, contains('向用户伸手邀请。'));
      expect(prompt, contains('双手叉腰。'));
      expect(prompt, contains('motionGroups'));
      expect(prompt, contains('action:none'));
      expect(prompt, contains('只能从其中选动作'));
    },
  );

  test('explicit none clears a previous action and does not replay it', () {
    const response = '''莱莎：[curious][face:neutral][action:think] 想想看。
莱莎：[calm][face:neutral][action:none] 我还在听。''';
    final cue = performanceCueForAssistantResponse(response);
    final segments = performanceSegmentsForAssistantResponse(
      response,
      fallbackMood: CharacterMood.neutral,
    );

    expect(cue.action, CharacterAction.none);
    expect(cue.actions, [CharacterAction.think]);
    expect(cue.actionCueCount, 2);
    expect(segments.last.action, CharacterAction.none);
    expect(segments.last.actions, isEmpty);
  });

  test('narrator and NPC action-looking text never drives Ryza motion', () {
    const response = '''旁白：[action:wave] 莱莎挥手。
角色[父亲]：[action:think] 这只是台词中的字样。
莱莎：[happy][face:happy][action:acknowledge] 嗯！''';
    final cue = performanceCueForAssistantResponse(response);

    expect(cue.action, CharacterAction.acknowledge);
    expect(cue.actions, [CharacterAction.acknowledge]);
    expect(cue.actionCueCount, 1);
  });
}
