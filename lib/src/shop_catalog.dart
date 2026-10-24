import 'app_localization.dart';

class ShopItem {
  const ShopItem({
    required this.id,
    required this.price,
    required this.imageAsset,
    required this.nameZh,
    required this.nameEn,
    required this.nameJa,
    required this.descriptionZh,
    required this.descriptionEn,
    required this.descriptionJa,
    required this.effectZh,
    required this.effectEn,
    required this.effectJa,
    required this.statChanges,
    this.resetNegativeStats = false,
    this.isKeepsake = false,
  });

  final String id;
  final int price;
  final String imageAsset;
  final String nameZh;
  final String nameEn;
  final String nameJa;
  final String descriptionZh;
  final String descriptionEn;
  final String descriptionJa;
  final String effectZh;
  final String effectEn;
  final String effectJa;
  final Map<String, int> statChanges;
  final bool resetNegativeStats;
  final bool isKeepsake;

  String name(AppLanguage language, {String? characterName}) => _forCharacter(
    language.text(nameZh, nameEn, nameJa),
    language,
    characterName,
  );
  String description(AppLanguage language, {String? characterName}) =>
      _forCharacter(
        language.text(descriptionZh, descriptionEn, descriptionJa),
        language,
        characterName,
      );

  String _forCharacter(String text, AppLanguage language, String? name) =>
      text.replaceAll(
        '{character}',
        name?.trim().isNotEmpty == true
            ? name!.trim()
            : language.text('当前角色', 'the current character', '現在のキャラクター'),
      );
  String effect(AppLanguage language) =>
      language.text(effectZh, effectEn, effectJa);
}

class ShopCatalog {
  static const oathRingId = 'oath_ring';
  static const reconciliationVoucherId = 'reconciliation_voucher';
  static const items = <ShopItem>[
    ShopItem(
      id: 'ryza_gift',
      price: 50,
      imageAsset: 'assets/images/shop/gift-box.png',
      nameZh: '给{character}的礼物',
      nameEn: 'A Gift for {character}',
      nameJa: '{character}への贈り物',
      descriptionZh: '你精心为{character}挑选的礼物。\n从挑选到包装都花了不少心思，期待打开时那份惊喜与快乐。',
      descriptionEn: 'A gift you chose for {character} with care, thoughtfully selected and wrapped for a happy surprise.',
      descriptionJa:
          '{character}のために心を込めて選んだ贈り物。選ぶところから包むところまで、喜んでもらえるように工夫しました。',
      effectZh: '心情 +10 · 精力 +5 · 亲近感 +10 · 好奇心 +5',
      effectEn: 'Mood +10 · Energy +5 · Closeness +10 · Curiosity +5',
      effectJa: '気分 +10 · 元気 +5 · 親しみ +10 · 好奇心 +5',
      statChanges: {'mood': 10, 'energy': 5, 'closeness': 10, 'curiosity': 5},
    ),
    ShopItem(
      id: 'advanced_energy_tonic',
      price: 150,
      imageAsset: 'assets/images/shop/energy-potion.png',
      nameZh: '高级精力剂',
      nameEn: 'Advanced Energy Tonic',
      nameJa: '高級活力剤',
      descriptionZh: '以稀有素材制作的高级精力剂。\n收集与制作都不容易，因此每一瓶都十分珍贵。',
      descriptionEn: 'An advanced energy tonic made from rare ingredients. Its demanding preparation makes every bottle precious.',
      descriptionJa: '希少な素材から作られた高級活力剤。収集も製作も難しく、一本一本が貴重です。',
      effectZh: '精力 +50 · 心情 -30 · 亲近感 -30（最低为 0）',
      effectEn: 'Energy +50 · Mood -30 · Closeness -30 (minimum 0)',
      effectJa: '元気 +50 · 気分 -30 · 親しみ -30（最低 0）',
      statChanges: {'energy': 50, 'mood': -30, 'closeness': -30},
    ),
    ShopItem(
      id: 'reconciliation_voucher',
      price: 200,
      imageAsset: 'assets/images/shop/reconciliation-voucher.png',
      nameZh: '和好券',
      nameEn: 'Make-Up Voucher',
      nameJa: '仲直り券',
      descriptionZh: '「如果以后我们吵架了，就用这个吧。」\n凭此券，可以兑换一次：不计较谁先道歉的和好。\n使用条件：双方其实都还在乎对方。\n不可转让 / 不可退款 / 永久有效',
      descriptionEn: '“If we ever argue, use this.” Redeem it once to make up without keeping score of who apologizes first. Valid when both of you still care. Non-transferable / Non-refundable / Never expires.',
      descriptionJa: '「もし喧嘩したら、これを使おう。」先に謝るのがどちらかを気にせず、仲直りを一度だけお願いできる券。条件は、お互いをまだ大切に思っていること。譲渡不可 / 返金不可 / 有効期限なし。',
      effectZh: '所有负值归零',
      effectEn: 'Reset negative stats to zero',
      effectJa: 'マイナスの数値をすべて 0 に戻す',
      statChanges: {},
      resetNegativeStats: true,
    ),
    ShopItem(
      id: 'iphone_18_pro_max',
      price: 499,
      imageAsset: 'assets/images/shop/iphone-18-pro-max.png',
      nameZh: 'IPhone 18 Pro Max',
      nameEn: 'IPhone 18 Pro Max',
      nameJa: 'IPhone 18 Pro Max',
      descriptionZh: '异世界最新的强劲工具，似乎对知识的搜集以及各种状态有增幅的效果',
      descriptionEn: 'The latest powerful tool from another world. It seems to aid gathering knowledge and enhance various states.',
      descriptionJa: '異世界の最新の強力な道具。知識の収集やさまざまな状態を高める効果があるようだ。',
      effectZh: '心情 +100',
      effectEn: 'Mood +100',
      effectJa: '気分 +100',
      statChanges: {'mood': 100},
    ),
    ShopItem(
      id: oathRingId,
      price: 4999,
      imageAsset: 'assets/images/shop/oath-ring.png',
      nameZh: '誓约之戒',
      nameEn: 'Ring of Vows',
      nameJa: '誓いの指輪',
      descriptionZh:
          '将彼此的约定珍藏在一枚戒指中。购买后放入「珍贵的东西」，不会作为消耗品使用。请好好保管，这是{character}十分珍视的约定。',
      descriptionEn: 'A ring holding a promise between you and {character}. Stored in Precious things after purchase, it is a keepsake rather than a consumable. Please keep this cherished promise safe.',
      descriptionJa: '二人の約束を込めた指輪。購入後は「大切なもの」に保管され、消費はされません。{character}が大切にしている約束を、どうかなくさないでください。',
      effectZh: '确认丢失后心情 −500；心情恢复到 −250（含）以上前，无法购买和好券。',
      effectEn: 'Confirmed loss: Mood −500. Make-Up Vouchers cannot be purchased until mood reaches −250 or higher.',
      effectJa: '紛失を確定すると気分 −500。気分が −250 以上に回復するまで仲直り券は購入できません。',
      statChanges: {},
      isKeepsake: true,
    ),
  ];

  static ShopItem? byId(String id) {
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }
}
