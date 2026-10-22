import 'app_localization.dart';

enum QuestObjectiveType { gather, synthesize, travel, chat }

extension QuestObjectiveTypeData on QuestObjectiveType {
  String label(AppLanguage language) => switch (this) {
    QuestObjectiveType.gather => language.text('采集', 'Gather', '採取'),
    QuestObjectiveType.synthesize => language.text('调合', 'Synthesize', '調合'),
    QuestObjectiveType.travel => language.text('旅行', 'Travel', '移動'),
    QuestObjectiveType.chat => language.text('交流', 'Talk', '会話'),
  };

  int rewardFor(int target) => switch (this) {
    QuestObjectiveType.gather => target * 8,
    QuestObjectiveType.synthesize => target * 15,
    QuestObjectiveType.travel => target * 6,
    QuestObjectiveType.chat => target * 3,
  };
}

class StoryQuestDefinition {
  const StoryQuestDefinition({
    required this.id,
    required this.titleZh,
    required this.titleEn,
    required this.titleJa,
    required this.descriptionZh,
    required this.descriptionEn,
    required this.descriptionJa,
    required this.objectiveType,
    required this.target,
    required this.reward,
  });

  final String id;
  final String titleZh;
  final String titleEn;
  final String titleJa;
  final String descriptionZh;
  final String descriptionEn;
  final String descriptionJa;
  final QuestObjectiveType objectiveType;
  final int target;
  final int reward;

  String title(AppLanguage language) =>
      language.text(titleZh, titleEn, titleJa);

  String description(AppLanguage language) =>
      language.text(descriptionZh, descriptionEn, descriptionJa);
}

/// A compact, original retelling of the first game's broad story progression.
/// These are not copied quest titles or scripts from the commercial game.
const builtInStoryQuests = <StoryQuestDefinition>[
  StoryQuestDefinition(
    id: 'story_01_cross_the_lake',
    titleZh: '越过湖面',
    titleEn: 'Across the Lake',
    titleJa: '湖を越えて',
    descriptionZh: '离开熟悉的岛岸，前往一个新的地点展开调查。',
    descriptionEn:
        'Leave the familiar shore and travel somewhere new to investigate.',
    descriptionJa: '慣れ親しんだ島岸を離れ、新しい場所へ調査に向かう。',
    objectiveType: QuestObjectiveType.travel,
    target: 1,
    reward: 12,
  ),
  StoryQuestDefinition(
    id: 'story_02_unfamiliar_travelers',
    titleZh: '陌生旅人的教导',
    titleEn: 'Lessons from Travelers',
    titleJa: '旅人たちの教え',
    descriptionZh: '和莱莎交流两次，梳理旅途中见到的新知识。',
    descriptionEn: 'Talk with Ryza twice and sort through what you learned on the journey.',
    descriptionJa: 'ライザと二度話し、旅で得た新しい知識を整理する。',
    objectiveType: QuestObjectiveType.chat,
    target: 2,
    reward: 10,
  ),
  StoryQuestDefinition(
    id: 'story_03_first_materials',
    titleZh: '第一篮素材',
    titleEn: 'The First Basket',
    titleJa: '最初の素材かご',
    descriptionZh: '在野外完成一次采集，为第一次正式调合作准备。',
    descriptionEn:
        'Gather once in the field to prepare for your first proper synthesis.',
    descriptionJa: '初めての本格的な調合に備え、野外で一度採取する。',
    objectiveType: QuestObjectiveType.gather,
    target: 1,
    reward: 14,
  ),
  StoryQuestDefinition(
    id: 'story_04_first_synthesis',
    titleZh: '炼金术的第一步',
    titleEn: 'First Step in Alchemy',
    titleJa: '錬金術の第一歩',
    descriptionZh: '使用亲手收集的素材完成一次调合。',
    descriptionEn:
        'Complete one synthesis using materials you gathered yourself.',
    descriptionJa: '自分で集めた素材を使い、一度調合を完成させる。',
    objectiveType: QuestObjectiveType.synthesize,
    target: 1,
    reward: 20,
  ),
  StoryQuestDefinition(
    id: 'story_05_secret_hideout',
    titleZh: '三人的秘密基地',
    titleEn: 'A Secret Hideout',
    titleJa: '三人の秘密基地',
    descriptionZh: '寻找适合建立据点的地方，并为新的工房踏出一步。',
    descriptionEn:
        'Travel to find a place suitable for a base and a new atelier.',
    descriptionJa: '拠点と新しいアトリエにふさわしい場所を探しに行く。',
    objectiveType: QuestObjectiveType.travel,
    target: 1,
    reward: 14,
  ),
  StoryQuestDefinition(
    id: 'story_06_build_the_base',
    titleZh: '为藏身处奔走',
    titleEn: 'Supplies for the Hideout',
    titleJa: '隠れ家のために',
    descriptionZh: '完成两次采集，把建设藏身处需要的素材带回来。',
    descriptionEn: 'Gather twice and bring back supplies for the hideout.',
    descriptionJa: '二度採取し、隠れ家づくりに必要な素材を持ち帰る。',
    objectiveType: QuestObjectiveType.gather,
    target: 2,
    reward: 22,
  ),
  StoryQuestDefinition(
    id: 'story_07_new_companion',
    titleZh: '新伙伴的来访',
    titleEn: 'A New Companion',
    titleJa: '新しい仲間',
    descriptionZh: '通过两次交流了解新伙伴的想法和顾虑。',
    descriptionEn:
        'Talk twice to learn about a new companion and their concerns.',
    descriptionJa: '二度会話し、新しい仲間の考えや悩みを知る。',
    objectiveType: QuestObjectiveType.chat,
    target: 2,
    reward: 12,
  ),
  StoryQuestDefinition(
    id: 'story_08_deeper_into_the_forest',
    titleZh: '森林深处的调查',
    titleEn: 'Deeper into the Forest',
    titleJa: '森の奥を調べて',
    descriptionZh: '前往两个不同地点，追查森林中出现的异常。',
    descriptionEn:
        'Visit two different places and investigate the forest disturbance.',
    descriptionJa: '二つの場所を訪れ、森で起きている異変を調べる。',
    objectiveType: QuestObjectiveType.travel,
    target: 2,
    reward: 20,
  ),
  StoryQuestDefinition(
    id: 'story_09_sunken_clues',
    titleZh: '水没遗迹的线索',
    titleEn: 'Clues in the Sunken Ruins',
    titleJa: '水没遺跡の手がかり',
    descriptionZh: '完成两次采集，从遗迹周边的素材中寻找线索。',
    descriptionEn:
        'Gather twice and search the materials around the ruins for clues.',
    descriptionJa: '二度採取し、遺跡周辺の素材から手がかりを探す。',
    objectiveType: QuestObjectiveType.gather,
    target: 2,
    reward: 24,
  ),
  StoryQuestDefinition(
    id: 'story_10_ancient_mechanism',
    titleZh: '古老机关的谜题',
    titleEn: 'The Ancient Mechanism',
    titleJa: '古い仕掛けの謎',
    descriptionZh: '完成两次调合，尝试制作破解遗迹机关的幻想道具。',
    descriptionEn:
        'Synthesize twice and devise a fantasy tool for the ruin mechanism.',
    descriptionJa: '二度調合し、遺跡の仕掛けを解く幻想道具を考える。',
    objectiveType: QuestObjectiveType.synthesize,
    target: 2,
    reward: 34,
  ),
  StoryQuestDefinition(
    id: 'story_11_island_requests',
    titleZh: '岛上居民的委托',
    titleEn: 'Requests from the Island',
    titleJa: '島の人々の依頼',
    descriptionZh: '和莱莎交流三次，商量如何用炼金术帮助岛上的居民。',
    descriptionEn:
        'Talk with Ryza three times about helping the island through alchemy.',
    descriptionJa: '三度話し、錬金術で島の人々を助ける方法を相談する。',
    objectiveType: QuestObjectiveType.chat,
    target: 3,
    reward: 16,
  ),
  StoryQuestDefinition(
    id: 'story_12_tower_records',
    titleZh: '高塔留下的记录',
    titleEn: 'Records of the Tower',
    titleJa: '塔に残された記録',
    descriptionZh: '前往两个地点，继续追寻岛屿和遗迹的过去。',
    descriptionEn:
        'Travel to two places and continue tracing the island\'s past.',
    descriptionJa: '二つの場所へ向かい、島と遺跡の過去を追い続ける。',
    objectiveType: QuestObjectiveType.travel,
    target: 2,
    reward: 22,
  ),
  StoryQuestDefinition(
    id: 'story_13_alchemists_responsibility',
    titleZh: '炼金术士的责任',
    titleEn: "An Alchemist's Responsibility",
    titleJa: '錬金術士の責任',
    descriptionZh: '完成两次调合，用可靠的成品回应伙伴的期待。',
    descriptionEn:
        'Synthesize twice and answer your companions with dependable items.',
    descriptionJa: '二度調合し、確かな道具で仲間の期待に応える。',
    objectiveType: QuestObjectiveType.synthesize,
    target: 2,
    reward: 36,
  ),
  StoryQuestDefinition(
    id: 'story_14_growing_threat',
    titleZh: '逼近岛屿的威胁',
    titleEn: 'A Threat Draws Near',
    titleJa: '島に迫る脅威',
    descriptionZh: '完成三次采集，为应对逐渐清晰的威胁储备素材。',
    descriptionEn:
        'Gather three times to stock materials against the growing threat.',
    descriptionJa: '三度採取し、迫る脅威に備えて素材を蓄える。',
    objectiveType: QuestObjectiveType.gather,
    target: 3,
    reward: 32,
  ),
  StoryQuestDefinition(
    id: 'story_15_prepare_for_the_gate',
    titleZh: '门扉之前的准备',
    titleEn: 'Preparing for the Gate',
    titleJa: '門へ向かう準備',
    descriptionZh: '完成三次调合，准备探索未知世界所需的道具。',
    descriptionEn: 'Synthesize three times to prepare for an unknown world.',
    descriptionJa: '三度調合し、未知の世界を探索する道具を整える。',
    objectiveType: QuestObjectiveType.synthesize,
    target: 3,
    reward: 50,
  ),
  StoryQuestDefinition(
    id: 'story_16_beyond_the_gate',
    titleZh: '门后的世界',
    titleEn: 'The World Beyond',
    titleJa: '門の向こうの世界',
    descriptionZh: '连续前往三个地点，踏入陌生而危险的领域。',
    descriptionEn:
        'Travel to three places and enter an unfamiliar, dangerous realm.',
    descriptionJa: '三つの場所へ進み、見知らぬ危険な領域へ踏み込む。',
    objectiveType: QuestObjectiveType.travel,
    target: 3,
    reward: 34,
  ),
  StoryQuestDefinition(
    id: 'story_17_truth_of_the_enemy',
    titleZh: '敌人与故乡的真相',
    titleEn: 'Truth of the Enemy',
    titleJa: '敵と故郷の真実',
    descriptionZh: '和莱莎交流三次，整理旅途中发现的真相与选择。',
    descriptionEn:
        'Talk with Ryza three times about the truths and choices you found.',
    descriptionJa: '三度話し、旅で知った真実と選択を整理する。',
    objectiveType: QuestObjectiveType.chat,
    target: 3,
    reward: 20,
  ),
  StoryQuestDefinition(
    id: 'story_18_before_the_final_battle',
    titleZh: '决战前夜',
    titleEn: 'Eve of the Final Battle',
    titleJa: '決戦前夜',
    descriptionZh: '完成三次采集，为伙伴们准备最后一批关键素材。',
    descriptionEn:
        'Gather three times and secure the last key materials for everyone.',
    descriptionJa: '三度採取し、仲間のために最後の重要素材を集める。',
    objectiveType: QuestObjectiveType.gather,
    target: 3,
    reward: 36,
  ),
  StoryQuestDefinition(
    id: 'story_19_protect_kurken',
    titleZh: '守护库肯岛',
    titleEn: 'Protect Kurken Island',
    titleJa: 'クーケン島を守る',
    descriptionZh: '完成三次调合，以炼金术为守护故乡做好准备。',
    descriptionEn:
        'Synthesize three times and prepare to protect your home with alchemy.',
    descriptionJa: '三度調合し、錬金術で故郷を守る準備を完成させる。',
    objectiveType: QuestObjectiveType.synthesize,
    target: 3,
    reward: 60,
  ),
  StoryQuestDefinition(
    id: 'story_20_a_new_journey',
    titleZh: '未完的夏日与新旅程',
    titleEn: 'A Summer Still Unfolding',
    titleJa: '続いていく夏と新しい旅',
    descriptionZh: '和莱莎交流四次，谈谈一路的成长以及下一次冒险。',
    descriptionEn:
        'Talk with Ryza four times about your growth and the next adventure.',
    descriptionJa: '四度話し、これまでの成長と次の冒険について語り合う。',
    objectiveType: QuestObjectiveType.chat,
    target: 4,
    reward: 30,
  ),
];

class DynamicQuest {
  const DynamicQuest({
    required this.id,
    required this.title,
    required this.description,
    required this.objectiveType,
    required this.target,
    required this.progressBaseline,
    required this.reward,
    required this.createdAt,
    required this.language,
    this.claimedAt,
  });

  final String id;
  final String title;
  final String description;
  final QuestObjectiveType objectiveType;
  final int target;
  final int progressBaseline;
  final int reward;
  final DateTime createdAt;
  final AppLanguage language;
  final DateTime? claimedAt;

  bool get isClaimed => claimedAt != null;

  int progressFor(int currentValue) =>
      (currentValue - progressBaseline).clamp(0, target);

  bool isCompleteFor(int currentValue) => progressFor(currentValue) >= target;

  DynamicQuest copyWith({DateTime? claimedAt}) => DynamicQuest(
    id: id,
    title: title,
    description: description,
    objectiveType: objectiveType,
    target: target,
    progressBaseline: progressBaseline,
    reward: reward,
    createdAt: createdAt,
    language: language,
    claimedAt: claimedAt ?? this.claimedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'objectiveType': objectiveType.name,
    'target': target,
    'progressBaseline': progressBaseline,
    'reward': reward,
    'createdAt': createdAt.toIso8601String(),
    'language': language.name,
    if (claimedAt != null) 'claimedAt': claimedAt!.toIso8601String(),
  };

  factory DynamicQuest.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String? ?? '').trim();
    final title = (json['title'] as String? ?? '').trim();
    final description = (json['description'] as String? ?? '').trim();
    final createdAt = DateTime.tryParse(json['createdAt'] as String? ?? '');
    if (id.isEmpty ||
        title.isEmpty ||
        description.isEmpty ||
        createdAt == null) {
      throw const FormatException('任务数据不完整');
    }
    final objectiveType = QuestObjectiveType.values.firstWhere(
      (value) => value.name == json['objectiveType'],
      orElse: () => throw const FormatException('任务目标类型无效'),
    );
    final target = (json['target'] as num? ?? 1).round();
    if (target < 1 || target > 10) {
      throw const FormatException('任务目标数量无效');
    }
    return DynamicQuest(
      id: id,
      title: title,
      description: description,
      objectiveType: objectiveType,
      target: target,
      progressBaseline: (json['progressBaseline'] as num? ?? 0).round().clamp(
        0,
        1 << 30,
      ),
      reward: (json['reward'] as num? ?? objectiveType.rewardFor(target))
          .round()
          .clamp(0, 1000),
      createdAt: createdAt,
      language: AppLanguage.values.firstWhere(
        (value) => value.name == json['language'],
        orElse: () => AppLanguage.chinese,
      ),
      claimedAt: DateTime.tryParse(json['claimedAt'] as String? ?? ''),
    );
  }
}
