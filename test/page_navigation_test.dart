import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/page_navigation.dart';

void main() {
  test('page switches return in reverse order without leaving home', () {
    final navigation = PageNavigation('chat');
    for (final page in [
      'map',
      'alchemy',
      'missions',
      'alarms',
      'settings',
      'logs',
    ]) {
      navigation.select(page);
    }
    for (final page in [
      'logs',
      'settings',
      'alarms',
      'missions',
      'alchemy',
      'map',
    ]) {
      expect(navigation.current, page);
      expect(navigation.canGoBack, isTrue);
      navigation.goBack();
    }
    expect(navigation.current, 'chat');
    expect(navigation.canGoBack, isFalse);
    navigation.goBack();
    expect(navigation.current, 'chat');
  });

  test(
    'same-page selection adds no duplicate and explicit home resets history',
    () {
      final navigation = PageNavigation('chat');
      navigation.select('map');
      navigation.select('map');
      navigation.goBack();
      expect(navigation.current, 'chat');
      navigation.select('settings');
      navigation.select('map');
      navigation.select('chat');
      expect(navigation.canGoBack, isFalse);
      navigation.select('logs');
      navigation.goBack();
      expect(navigation.current, 'chat');
    },
  );
}
