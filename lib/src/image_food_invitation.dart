/// A current image can be offered as food only when the user's own message
/// explicitly invites the character to eat or taste it. The model still has
/// to inspect the image and confirm that it contains edible food.
bool hasCurrentImageFoodInvitation(
  String message, {
  required bool hasReadableImage,
  String? characterName,
}) =>
    hasReadableImage &&
    isExplicitImageFoodInvitation(message, characterName: characterName);

bool isExplicitImageFoodInvitation(String message, {String? characterName}) {
  // Legacy aliases are accepted only by callers without an active identity.
  // A model name is escaped as data, never treated as a regex or an alias for
  // another character when authorizing this turn's state change.
  const legacyAliases = ['莱莎', '莱沙', 'ryza', 'ライザ'];
  final currentName = characterName?.trim() ?? '';
  final addressedCharacter =
      (currentName.isEmpty ? legacyAliases : [currentName])
          .map(RegExp.escape)
          .join('|');
  final otherLegacyNames = legacyAliases
      .where((name) => name.toLowerCase() != currentName.toLowerCase())
      .map(RegExp.escape)
      .join('|');
  final text = message.toLowerCase().replaceAll(
    RegExp(r'“[^”]*”|‘[^’]*’|"[^"]*"'),
    '',
  );
  if (text.trim().isEmpty) return false;

  final sentenceContent = [
    if (characterName?.trim().isNotEmpty == true)
      RegExp.escape(characterName!.trim()),
    r'[^。.!！?？\n；;]',
  ].join('|');
  final sentences = RegExp(
    '(?:$sentenceContent)+'
    r'[。.!！?？]?',
    caseSensitive: false,
  ).allMatches(text).map((match) => match.group(0)!.trim());
  for (final sentence in sentences) {
    if (currentName.isNotEmpty &&
        RegExp(
          '(?:^|[:：])\\s*(?:$otherLegacyNames)'
          '[，,、:：\\s]|(?:请|請|邀请|邀請|让|讓|给|給|喂|餵)\\s*'
          '(?:$otherLegacyNames)',
          caseSensitive: false,
        ).hasMatch(sentence)) {
      continue;
    }
    if (RegExp(
      r'别|不要|不准|不能|禁止|勿|别让|不让|拒绝|don\x27t|do not|never|not to|食べない|食べるな|食べてはいけない',
      caseSensitive: false,
    ).hasMatch(sentence)) {
      continue;
    }
    if (RegExp(
      r'能吃吗|可以吃吗|能不能吃|可不可以吃|是否能吃|好吃吗|什么味道|能尝吗|can (?:you|she) eat|is (?:it|this) edible|吃了吗|吃了嗎|吃过吗|吃過嗎',
      caseSensitive: false,
    ).hasMatch(sentence)) {
      continue;
    }
    if (RegExp(
      r'喜欢吃|喜歡吃|已经吃|已經吃|以前吃|经常吃|經常吃|正在吃|吃过|吃過|吃了|吃過|会吃|會吃|想吃|能吃|可以吃|可能吃|如果|假如|假设|假設|要是|if ',
    ).hasMatch(sentence)) {
      continue;
    }
    final explicitRequest = RegExp(
      r'(?:请|請)[，,:：\s]*(?:' +
          addressedCharacter +
          r'|你|妳)?[，,:：\s]*(?:吃|尝|嚐|品尝|品嚐|试吃|試吃)|(?:邀请|邀請|让|讓|给|給|喂|餵)(?:' +
          addressedCharacter +
          r'|你|妳)[^。.!！?？\n；;]{0,6}(?:吃|尝|嚐|品尝|品嚐|试吃|試吃)',
      caseSensitive: false,
    ).hasMatch(sentence);
    final directCommand = RegExp(
      '(?:$addressedCharacter'
      r'|你|妳|来|來|一起)[，,:：\s]*(?:请|請|快|来|來|也|一起)?[，,:：\s]*(?:吃|尝|嚐|品尝|品嚐|试吃|試吃)(?:尝|嚐|这个|這個|这张|這張|这份|這份|这块|這塊|这道|這道|一口|一点|一點|一些|点|點|它|吧|呀|啦|啊|哦|喔)',
      caseSensitive: false,
    ).hasMatch(sentence);
    final invitationQuestion = RegExp(
      '(?:$addressedCharacter'
      r'|你|妳)[^。.!！?？\n；;]{0,8}(?:要不要|愿不愿意|願不願意)[^。.!！?？\n；;]{0,8}(?:吃|尝|嚐|品尝|品嚐|试吃|試吃)',
      caseSensitive: false,
    ).hasMatch(sentence);
    final englishRequest = RegExp(
      '(?:(?:$addressedCharacter)'
      r'[,:\s]+|please\s+|would you\s+|let\x27s\s+)(?:please\s+)?(?:eat|taste|try|have|take a bite)\s+(?:this|it|some|a bite|the food)',
      caseSensitive: false,
    ).hasMatch(sentence);
    final japaneseRequest = RegExp(r'食べて|食べよう|味見して').hasMatch(sentence);
    final command =
        explicitRequest || directCommand || englishRequest || japaneseRequest;
    if ((sentence.endsWith('?') || sentence.endsWith('？')) &&
        !invitationQuestion &&
        !RegExp(r'请|請|吧|please|would you').hasMatch(sentence)) {
      continue;
    }
    if (command || invitationQuestion) return true;
  }
  return false;
}
