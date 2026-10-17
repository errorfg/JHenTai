import 'dart:io';

import 'package:clipboard/clipboard.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get_utils/get_utils.dart';
import 'package:jhentai/src/consts/eh_consts.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/network/eh_igneous.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import 'package:jhentai/src/utils/cookie_util.dart';
import 'package:jhentai/src/utils/snack_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';


class CookiePage extends StatefulWidget {
  const CookiePage({super.key});

  @override
  State<CookiePage> createState() => _CookiePageState();
}

class _CookiePageState extends State<CookiePage> {
  LoadingState _refreshIgneousState = LoadingState.idle;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text('accountSetting'.tr),
        actions: [
          IconButton(icon: const Icon(Icons.copy), onPressed: _copyCookies),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 12),
        children: ehRequest.cookies
            .map(
              (cookie) => ListTile(
                title: Text(cookie.name),
                subtitle: Text(cookie.value),
                trailing: cookie.name == EHConsts.igneousCookieName
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LoadingStateIndicator(
                            loadingState: _refreshIgneousState,
                            loadingWidgetBuilder: () => const CupertinoActivityIndicator().marginOnly(right: 10),
                            idleWidgetBuilder: () => IconButton(icon: const Icon(Icons.refresh), onPressed: _refreshIgneousCookie),
                            successWidgetSameWithIdle: true,
                            errorWidgetSameWithIdle: true,
                          )
                        ],
                      )
                    : null,
                onTap: () => _copyCookie(cookie),
                dense: true,
              ),
            )
            .toList(),
      ).withListTileTheme(context),
    );
  }

  Future<void> _copyCookie(Cookie cookie) async {
    await FlutterClipboard.copy(CookieUtil.parse2String([cookie]));
    toast('hasCopiedToClipboard'.tr);
  }

  Future<void> _copyCookies() async {
    await FlutterClipboard.copy(
      CookieUtil.parse2String(
        ehRequest.cookies
            .where(
              (cookie) => cookie.name == 'ipb_member_id' || cookie.name == 'ipb_pass_hash' || cookie.name == 'igneous',
            )
            .toList(),
      ),
    );
    toast('hasCopiedToClipboard'.tr);
  }

  Future<void> _refreshIgneousCookie() async {
    if (!userSetting.hasLoggedIn()) {
      return;
    }

    if (_refreshIgneousState == LoadingState.loading) {
      return;
    }

    setStateSafely(() {
      _refreshIgneousState = LoadingState.loading;
    });

    IgneousRefresh refresh = await igneousRefresher.refresh(
      ipbMemberId: userSetting.ipbMemberId.value!,
      ipbPassHash: userSetting.ipbPassHash.value!,
    );
    if (refresh.result == IgneousResult.refreshed) {
      await ehRequest.storeEHCookies([Cookie(EHConsts.igneousCookieName, refresh.value!)]);
      toast('success'.tr);
      setStateSafely(() {
        _refreshIgneousState = LoadingState.success;
      });
      return;
    }

    snack('refreshIgneousFailed'.tr, refresh.message ?? '');
    setStateSafely(() {
      _refreshIgneousState = LoadingState.error;
    });
  }
}
