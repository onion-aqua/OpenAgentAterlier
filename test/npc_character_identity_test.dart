import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/character_catalog.dart';
import 'package:ryza_chat_mvp/src/character_identity.dart';
import 'package:ryza_chat_mvp/src/npc_chat_contacts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CharacterCatalog catalog;
  late List<NpcChatContact> ryzaContacts;
  late List<NpcChatContact> sophieContacts;
  setUpAll(() async {
    catalog = await CharacterCatalog.load();
    ryzaContacts = npcChatContactsFor('ryza', catalog);
    sophieContacts = npcChatContactsFor('sophie', catalog);
  });

  test(
    'catalog IDs, display names and every stored alias resolve identically',
    () {
      for (final profile in catalog.allProfiles) {
        for (final alias in [
          profile.id,
          profile.names.chinese,
          profile.names.english,
          profile.names.japanese,
          ...profile.aliases,
        ]) {
          expect(catalog.profile(alias)?.id, profile.id, reason: alias);
        }
      }
    },
  );

  test('Fee and Kala resolve through lookup, display and contact paths in all languages', () {
    final names = {
      'fee': ['fee', 'Fee', 'Fi', '菲', 'フィー', 'Ｆｅｅ'],
      'kala': [
        'kala',
        'Kala',
        'Kala Ideas',
        '卡菈',
        '卡拉',
        '卡菈·伊迪亚斯',
        'カラ',
        'カラ・イデアス',
        '卡菈・伊迪亚斯',
        'Ｋａｌａ',
      ],
    };
    for (final entry in names.entries) {
      for (final name in entry.value) {
        expect(catalog.profile(name)?.id, entry.key, reason: name);
        expect(
          catalog.displayName(name, AppLanguage.japanese),
          catalog.profile(entry.key)!.names.japanese,
          reason: name,
        );
        final lookup = jsonDecode(catalog.lookupPrompt(name)) as Map;
        expect(
          (lookup['characters'] as List).single['id'],
          entry.key,
          reason: name,
        );
        expect(
          resolveNpcContactId(name, catalog: catalog),
          entry.key,
          reason: name,
        );
        expect(
          resolveNpcContactId(name, contacts: ryzaContacts),
          entry.key,
          reason: name,
        );
      }
    }
  });

  test(
    'longer Chinese entities suppress Fee only at the covered occurrence',
    () {
      final examples = <String, Set<String>>{
        '菲德丽卡，可以交换联系方式吗？': {'federica'},
        '洁菲娜，可以交换联系方式吗？': {'zephine'},
        '问问苏菲，能交换联系方式吗？': {},
        '菲德丽卡和菲都来了。': {'federica', 'fee'},
        '苏菲不在，菲可以交换联系方式吗？': {'fee'},
        '洁菲娜与卡菈商量好了。': {'zephine', 'kala'},
        '卡菈，能加个微信吗？': {'kala'},
      };
      for (final entry in examples.entries) {
        expect(
          mentionedNpcContactIds(entry.key, catalog: catalog).toSet(),
          entry.value,
          reason: entry.key,
        );
        expect(
          ryzaContacts
              .where((c) => c.matchesMention(entry.key))
              .map((c) => c.id)
              .toSet(),
          entry.value,
          reason: entry.key,
        );
      }
    },
  );

  test(
    'Latin names retain complete-name boundaries after width normalization',
    () {
      expect(
        mentionedNpcContactIds('coffee, filing, talented', catalog: catalog),
        isEmpty,
      );
      expect(
        mentionedNpcContactIds(
          'FEE, can we exchange contacts?',
          catalog: catalog,
        ),
        ['fee'],
      );
      expect(mentionedNpcContactIds('Ｆｉ，可以交换联系方式吗？', catalog: catalog), [
        'fee',
      ]);
      expect(resolveNpcContactId('coffee', catalog: catalog), isNull);
      expect(resolveNpcContactId('可以找菲吗', catalog: catalog), isNull);
      expect(resolveNpcContactId('F', catalog: catalog), isNull);
    },
  );

  test('contact worlds never borrow IDs or aliases from each other', () {
    for (final name in ['kala', '卡菈', 'fee', '菲', 'フィー']) {
      expect(
        resolveNpcContactId(
          name,
          primaryCharacterId: 'sophie',
          catalog: catalog,
        ),
        isNull,
      );
    }
    for (final name in ['sophie_alette', '阿蕾特', 'Alette', 'アレット']) {
      expect(
        resolveNpcContactId(name, primaryCharacterId: 'sophie'),
        'sophie_alette',
      );
      expect(resolveNpcContactId(name, catalog: catalog), isNull);
    }
    expect(resolveNpcContactId('ryza', catalog: catalog), isNull);
    expect(
      resolveNpcContactId(
        'fee',
        primaryCharacterId: 'unknown',
        catalog: catalog,
      ),
      isNull,
    );
    final mixed = [...ryzaContacts, ...sophieContacts];
    expect(
      resolveNpcContactId('菲', primaryCharacterId: 'sophie', contacts: mixed),
      isNull,
    );
    expect(resolveNpcContactId('阿蕾特', contacts: mixed), isNull);
  });

  test('unqualified Plachta stays ambiguous and qualified identities stay distinct', () {
    for (final name in ['普拉芙妲', 'Plachta', 'プラフタ']) {
      expect(
        resolveNpcContactId(name, primaryCharacterId: 'sophie'),
        isNull,
        reason: name,
      );
      expect(
        mentionedNpcContactIds(name, primaryCharacterId: 'sophie').toSet(),
        {'sophie_plachta_doll', 'sophie_plachta_young'},
        reason: name,
      );
    }
    expect(
      resolveNpcContactId('Plachta（Doll）', primaryCharacterId: 'sophie'),
      'sophie_plachta_doll',
    );
    expect(
      resolveNpcContactId('普拉芙妲（年轻）', primaryCharacterId: 'sophie'),
      'sophie_plachta_young',
    );
    for (final name in ['普拉芙达（人形）', 'Doll プラフタ', '人偶 Plachta']) {
      expect(
        resolveNpcContactId(name, primaryCharacterId: 'sophie'),
        'sophie_plachta_doll',
        reason: name,
      );
    }
    expect(
      mentionedNpcContactIds(
        '人偶普拉芙妲与年轻普拉芙妲',
        primaryCharacterId: 'sophie',
      ).toSet(),
      {'sophie_plachta_doll', 'sophie_plachta_young'},
    );
    expect(
      sophieContacts
          .where((c) => c.matchesMention('Plachta（Young）说过的话'))
          .map((c) => c.id),
      ['sophie_plachta_young'],
    );
  });

  test('a duplicate alias never resolves by insertion order', () {
    final resolver = CharacterIdentityResolver([
      CharacterIdentityRecord(id: 'first', aliases: ['Shared']),
      CharacterIdentityRecord(id: 'second', aliases: ['Shared']),
    ]);
    expect(resolver.resolve('SHARED'), isNull);
    expect(resolver.resolve('first'), 'first');
    expect(resolver.mentionedIds('Shared'), {'first', 'second'});
  });
}
