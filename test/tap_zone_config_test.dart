import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/tap_zone_config.dart';
import 'package:jhentai/src/setting/read_setting.dart';

void main() {
  test('normalizes out-of-range ratios so derived segments stay >= 1', () {
    TapZoneConfig config = TapZoneConfig(
      actions: TapZoneConfig.classic().actions,
      leftColumnWidthRatio: 98,
      middleColumnWidthRatio: 60,
      topRowHeightRatio: 99,
      middleRowHeightRatio: 99,
    );
    expect(config.leftColumnWidthRatio, 98);
    expect(config.middleColumnWidthRatio, 1);
    expect(config.rightColumnWidthRatio, 1);
    expect(config.topRowHeightRatio, 98);
    expect(config.middleRowHeightRatio, 1);
    expect(config.bottomRowHeightRatio, 1);
  });

  test('json round-trip preserves normalized config', () {
    TapZoneConfig config = TapZoneConfig.fromJsonString(
      '{"actions":[0,3,2,0,3,2,0,3,2],"leftColumnWidthRatio":50,"middleColumnWidthRatio":49,"topRowHeightRatio":10,"middleRowHeightRatio":80}',
    );
    expect(config.rightColumnWidthRatio, 1);
    expect(config.bottomRowHeightRatio, 10);
    expect(TapZoneConfig.fromJsonString(config.toJsonString()), config);
  });

  group('settings saved before configurable tap zones', () {
    TapZoneConfig migrated(Map<String, dynamic> saved) {
      // A full saved config from a release before tap zones: today's keys
      // minus the tap zone config, plus the old settings under test.
      Map<String, dynamic> config = jsonDecode(ReadSetting().toConfigString())
        ..remove('tapZoneConfig')
        ..addAll(saved);
      ReadSetting setting = ReadSetting();
      setting.applyBeanConfig(jsonEncode(config));
      return setting.tapZoneConfig;
    }

    test('the old defaults become the classic layout', () {
      expect(TapZoneConfig.fromLegacySettings(), TapZoneConfig.classic());
      expect(migrated(<String, dynamic>{}), TapZoneConfig.classic());
    });

    test('a reversed turn direction and a custom width carry over', () {
      TapZoneConfig config = migrated(<String, dynamic>{
        'gestureRegionWidthRatio': 50,
        'reverseTurnPageDirection': true,
      });
      expect(config.leftColumnWidthRatio, 25);
      expect(config.middleColumnWidthRatio, 50);
      for (int row = 0; row < 3; row++) {
        expect(config.actions.sublist(row * 3, row * 3 + 3), [
          TapZoneAction.flipRight,
          TapZoneAction.toggleMenu,
          TapZoneAction.flipLeft,
        ]);
      }
    });

    test('disabled tap page turning leaves only the menu zones', () {
      TapZoneConfig config = migrated(<String, dynamic>{'disablePageTurningOnTap': true});
      expect(config.actions.where((a) => a != TapZoneAction.none), everyElement(TapZoneAction.toggleMenu));
      expect(config.actions.where((a) => a == TapZoneAction.toggleMenu).length, 3);
    });

    test('a saved tap zone config wins over the old settings', () {
      TapZoneConfig saved = TapZoneConfig.vertical();
      TapZoneConfig config = migrated(<String, dynamic>{
        'tapZoneConfig': saved.toJsonString(),
        'reverseTurnPageDirection': true,
      });
      expect(config, saved);
    });
  });
}
