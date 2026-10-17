import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/l18n/locale_text.dart';

/// The dialogs that choose what to sync or export list the types by their
/// translated names: every type has one in every language.
void main() {
  test('every sync type has a name in every language', () {
    final Map<String, Map<String, String>> languages = LocaleText().keys;
    for (final MapEntry<String, Map<String, String>> language in languages.entries) {
      for (final CloudConfigTypeEnum type in CloudConfigTypeEnum.values) {
        expect(language.value[type.name], isNotNull, reason: '${type.name} in ${language.key}');
        expect(language.value[type.name], isNot(type.name), reason: '${type.name} in ${language.key}');
      }
    }
  });
}
