import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:jhentai/src/consts/eh_consts.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/network/eh_igneous.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';

/// This device's E-Hentai cookies, as the login changes them.
abstract class EhCookieJar {
  List<Cookie> get cookies;

  Future<void> store(List<Cookie> cookies);

  Future<void> remove(List<String> names);

  /// What the logout button does: cookies and account gone.
  Future<void> logout();
}

class _RequestCookieJar implements EhCookieJar {
  @override
  List<Cookie> get cookies => ehRequest.cookies;

  @override
  Future<void> store(List<Cookie> cookies) => ehRequest.storeEHCookies(cookies);

  @override
  Future<void> remove(List<String> names) => ehRequest.removeCookies(names);

  @override
  Future<void> logout() => ehRequest.requestLogout();
}

typedef IgneousFetcher = Future<IgneousRefresh> Function({required int ipbMemberId, required String ipbPassHash});

/// The login as synced, and when it last changed (canonical).
typedef EhAccountValue = ({String value, String time});

EhAccountSync ehAccountSync = EhAccountSync();

/// The E-Hentai login as one synced value: the account in UserSetting and
/// the cookies that belong to the account.
///
/// igneous is not synced: ExHentai gives each session its own, so a device
/// that receives a login fetches one itself. Nor are the session's own
/// cookies (ipb_session_id, ipb_topicsread, event, star).
///
/// The time is that of the account (UserSetting), not of the cookies: the
/// cookie store is rewritten whenever the site sets any cookie, and a device
/// that merely browsed must not win over a login or logout made elsewhere.
class EhAccountSync {
  EhAccountSync({EhCookieJar? jar, IgneousFetcher? fetchIgneous})
      : jar = jar ?? _RequestCookieJar(),
        _fetchIgneous = fetchIgneous ?? igneousRefresher.refresh;

  static const Set<String> syncedCookies = {'ipb_member_id', 'ipb_pass_hash', 'sk', 'hath_perks'};

  final EhCookieJar jar;
  final IgneousFetcher _fetchIgneous;

  /// The igneous request started by the last [apply], if any.
  Future<void>? igneousFetch;

  /// Null on a device that never held a login: such a device takes the login
  /// of the others instead of sending them its being logged out.
  Future<EhAccountValue?> export() async {
    LocalConfig? user = await localConfigService.readRecord(configKey: ConfigEnum.userSetting);
    if (user == null) {
      return null;
    }

    Map<String, dynamic> account = Map<String, dynamic>.from(jsonDecode(user.value));
    List<String> cookies = [];
    if (account['ipbMemberId'] != null) {
      String? raw = await localConfigService.read(configKey: ConfigEnum.ehCookie);
      for (String text in raw == null ? <String>[] : (jsonDecode(raw) as List).cast<String>()) {
        Cookie cookie = Cookie.fromSetCookieValue(text);
        if (syncedCookies.contains(cookie.name)) {
          cookies.add('${cookie.name}=${cookie.value}');
        }
      }
      cookies.sort();
    }
    return (value: jsonEncode({'account': account, 'cookies': cookies}), time: SyncTimeUtil.canonicalize(user.utime));
  }

  /// Takes the login [value] of another device, keeping its [time].
  Future<void> apply(String value, String time) async {
    Map json = jsonDecode(value);
    Map<String, dynamic> account = Map<String, dynamic>.from(json['account'] ?? {});
    int? memberId = account['ipbMemberId'];
    int? before = userSetting.ipbMemberId.value;

    if (memberId == null) {
      if (before != null || jar.cookies.any((c) => c.name == 'ipb_member_id')) {
        await jar.logout();
      }
    } else {
      List<Cookie> cookies = [
        for (String pair in (json['cookies'] as List? ?? []).cast<String>())
          Cookie(pair.substring(0, pair.indexOf('=')), pair.substring(pair.indexOf('=') + 1)),
      ];
      Set<String> names = cookies.map((c) => c.name).toSet();
      await jar.remove([
        ...syncedCookies.where((name) => !names.contains(name)),
        // an igneous of another account is of no use
        if (before != memberId) EHConsts.igneousCookieName,
      ]);
      await jar.store(cookies);
    }

    await localConfigService.batchWrite([
      LocalConfigCompanion(
        configKey: Value(ConfigEnum.userSetting.key),
        subConfigKey: const Value(LocalConfigService.defaultSubConfigKey),
        value: Value(jsonEncode(account)),
        utime: Value(time),
      ),
    ]);
    await userSetting.refreshBean();
    log.info('E-Hentai login taken from sync: ${memberId == null ? 'logged out' : 'member $memberId'}');

    if (memberId != null && !_hasIgneous) {
      await localConfigService.write(configKey: ConfigEnum.ehIgneousPending, value: 'true');
      igneousFetch = fetchIgneousIfPending();
    }
  }

  /// After a logout here: an empty account, timed now, so that the logout
  /// reaches the other devices instead of their login coming back.
  Future<void> markLoggedOut() => userSetting.saveBeanConfig();

  bool _fetching = false;

  /// Gets this device's igneous for a login received through sync. A failed
  /// request leaves it pending, to be tried again at the next launch.
  Future<void> fetchIgneousIfPending() async {
    if (_fetching || await localConfigService.read(configKey: ConfigEnum.ehIgneousPending) != 'true') {
      return;
    }
    int? memberId = userSetting.ipbMemberId.value;
    String? passHash = userSetting.ipbPassHash.value;
    if (memberId == null || passHash == null || _hasIgneous) {
      await localConfigService.delete(configKey: ConfigEnum.ehIgneousPending);
      return;
    }

    _fetching = true;
    try {
      IgneousRefresh refresh = await _fetchIgneous(ipbMemberId: memberId, ipbPassHash: passHash);
      switch (refresh.result) {
        case IgneousResult.refreshed:
          await jar.store([Cookie(EHConsts.igneousCookieName, refresh.value!)]);
          await localConfigService.delete(configKey: ConfigEnum.ehIgneousPending);
          log.info('Got an igneous of this device for the synced login');
        case IgneousResult.noAccess:
          await localConfigService.delete(configKey: ConfigEnum.ehIgneousPending);
          log.info('The synced login has no ExHentai access');
        case IgneousResult.failed:
          log.warning('Getting an igneous for the synced login failed, trying again at the next launch: ${refresh.message}');
      }
    } finally {
      _fetching = false;
    }
  }

  bool get _hasIgneous => jar.cookies.any((c) => c.name == EHConsts.igneousCookieName && c.value != 'mystery');
}
