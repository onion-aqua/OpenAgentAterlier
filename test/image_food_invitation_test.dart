import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/image_food_invitation.dart';

void main() {
  test('recognizes a direct offer in the current user message', () {
    expect(isExplicitImageFoodInvitation('发言：莱莎，尝尝这张图里的蛋糕吧'), isTrue);
    expect(isExplicitImageFoodInvitation('发言：莱莎，吃这个吧'), isTrue);
    expect(isExplicitImageFoodInvitation('发言：莱莎尝一口'), isTrue);
    expect(isExplicitImageFoodInvitation('旁白：我邀请莱莎吃一块照片里的面包'), isTrue);
    expect(isExplicitImageFoodInvitation('Ryza, please try this food'), isTrue);
    expect(isExplicitImageFoodInvitation('please taste this'), isTrue);
    expect(isExplicitImageFoodInvitation('ライザ、これを食べて'), isTrue);
  });

  test('does not turn a description, question, or refusal into an offer', () {
    expect(isExplicitImageFoodInvitation('请分析我发送的附件。'), isFalse);
    expect(isExplicitImageFoodInvitation('发言：我吃了一块蛋糕'), isFalse);
    expect(isExplicitImageFoodInvitation('发言：莱莎，这个能吃吗？'), isFalse);
    expect(isExplicitImageFoodInvitation('发言：你吃饭了吗？'), isFalse);
    expect(isExplicitImageFoodInvitation('发言：莱莎吃过了吗？'), isFalse);
    expect(isExplicitImageFoodInvitation('发言：如果莱莎吃了这份会怎样？'), isFalse);
    expect(isExplicitImageFoodInvitation('发言：图片上写着“莱莎，吃这个吧”'), isFalse);
    expect(isExplicitImageFoodInvitation('发言：莱莎以前吃过这道菜'), isFalse);
    expect(isExplicitImageFoodInvitation('发言：莱莎喜欢吃蛋糕'), isFalse);
    expect(isExplicitImageFoodInvitation('发言：请分析莱莎吃了什么'), isFalse);
    expect(isExplicitImageFoodInvitation('发言：莱莎，别吃这张图里的东西'), isFalse);
    expect(isExplicitImageFoodInvitation('发言：Ryza, do not eat this'), isFalse);
  });

  test('requires a readable image from this turn', () {
    const offer = '发言：莱莎，请吃这份蛋糕';
    expect(
      hasCurrentImageFoodInvitation(offer, hasReadableImage: false),
      isFalse,
    );
    expect(
      hasCurrentImageFoodInvitation(offer, hasReadableImage: true),
      isTrue,
    );
  });

  test('current character names retain invitation and refusal boundaries', () {
    for (final name in ['星见', 'Akari', 'A.*']) {
      expect(
        hasCurrentImageFoodInvitation(
          '$name，尝一口',
          hasReadableImage: true,
          characterName: name,
        ),
        isTrue,
      );
      for (final text in ['$name，别吃这个', '如果$name尝一口会怎样？', '图片上写着“$name，尝一口”']) {
        expect(
          isExplicitImageFoodInvitation(text, characterName: name),
          isFalse,
          reason: text,
        );
      }
    }
    expect(
      isExplicitImageFoodInvitation('Akari, try this', characterName: 'Akari'),
      isTrue,
    );
    expect(
      isExplicitImageFoodInvitation('Able，尝一口', characterName: 'A.*'),
      isFalse,
    );
    for (final text in [
      '请莱莎吃这张图里的蛋糕',
      '发言：莱莎，尝尝这个',
      '旁白：我邀请莱莎吃这个',
      'Ryza, please taste this',
      'ライザ、これを食べて',
    ]) {
      expect(
        isExplicitImageFoodInvitation(text, characterName: '星见'),
        isFalse,
        reason: 'A request addressed to a different character: $text',
      );
    }
    expect(
      isExplicitImageFoodInvitation('星见，尝尝莱莎做的蛋糕', characterName: '星见'),
      isTrue,
    );
  });
}
