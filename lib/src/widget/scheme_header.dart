import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/model/content_scheme.dart';
import 'package:jhentai/src/pages/setting/account/login/login_page_state.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/setting/scheme_setting.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import 'package:jhentai/src/utils/account_util.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/widget/eh_alert_dialog.dart';

/// Shows [target] in place of [current]. A site becomes the saved site and
/// fills the navigation; Komga and PDF open their own pages on top.
Future<void> switchScheme(
  ContentScheme current,
  ContentScheme target, {
  VoidCallback? onBeforeSwitch,
}) async {
  if (target == current) {
    return;
  }
  onBeforeSwitch?.call();

  if (target.isSite) {
    await schemeSetting.saveSite(target);
    if (!current.isSite) {
      Get.offAllNamed(Routes.home);
    }
    return;
  }

  final String routeName = target == ContentScheme.komga ? Routes.komga : Routes.pdfLibrary;
  if (current.isSite) {
    Get.toNamed(routeName);
  } else {
    Get.offNamed(routeName);
  }
}

/// Logs in to [site], or offers to log out when already logged in.
Future<void> handleTapAccount(LoginSite site) async {
  if (!isLoggedIn(site)) {
    toRoute(Routes.login, arguments: site);
    return;
  }
  bool? result = await Get.dialog(EHDialog(title: '${'logout'.tr} ${site.title}?'));
  if (result == true) {
    await logout(site);
  }
}

String? _accountText(ContentScheme scheme) {
  final LoginSite? site = scheme.loginSite;
  if (site != null) {
    return accountLabel(site) ?? 'tap2Login'.tr;
  }
  return scheme == ContentScheme.wnacg ? 'noAccountNeeded'.tr : null;
}

/// Top of the navigation drawer: picks the scheme and shows the account of
/// the scheme on screen.
class SchemeHeader extends StatelessWidget {
  const SchemeHeader({super.key, this.current, this.onBeforeSwitch});

  /// The scheme on screen; null for the saved site.
  final ContentScheme? current;

  /// Called before switching, e.g. to close the drawer.
  final VoidCallback? onBeforeSwitch;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 120,
      alignment: Alignment.center,
      child: Obx(() {
        // Read in every case: Obx needs an observable even on pages of
        // their own, where the scheme is fixed.
        final ContentScheme savedSite = schemeSetting.site.value;
        final ContentScheme scheme = current ?? savedSite;
        final LoginSite? site = scheme.loginSite;
        final String? avatarUrl = scheme == ContentScheme.ehentai ? userSetting.avatarImgUrl.value : null;
        final String? account = _accountText(scheme);

        return ListTile(
          leading: CircleAvatar(
            radius: 28,
            backgroundColor: UIConfig.loginAvatarBackGroundColor(context),
            foregroundImage: avatarUrl != null ? ExtendedNetworkImageProvider(avatarUrl, cache: true) : null,
            child: Icon(scheme.icon, color: UIConfig.loginAvatarForeGroundColor(context), size: 28),
          ),
          title: Align(
            alignment: AlignmentDirectional.centerStart,
            child: SchemePicker(current: scheme, onBeforeSwitch: onBeforeSwitch),
          ),
          subtitle: account == null ? null : Text(account, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: site == null ? null : () => handleTapAccount(site),
        );
      }),
    );
  }
}

/// The scheme's name with a drop-down arrow; opens the list of schemes.
class SchemePicker extends StatelessWidget {
  const SchemePicker({super.key, required this.current, this.onBeforeSwitch});

  final ContentScheme current;
  final VoidCallback? onBeforeSwitch;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<ContentScheme>(
      key: const Key('schemePicker'),
      tooltip: 'switchScheme'.tr,
      initialValue: current,
      onSelected: (ContentScheme target) => switchScheme(current, target, onBeforeSwitch: onBeforeSwitch),
      itemBuilder: (_) => _schemeItems(current),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              current.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    );
  }
}

List<PopupMenuEntry<ContentScheme>> _schemeItems(ContentScheme current) => [
  for (final ContentScheme scheme in ContentScheme.values) ...[
    if (scheme == ContentScheme.komga) const PopupMenuDivider(),
    PopupMenuItem<ContentScheme>(
      value: scheme,
      child: Row(
        children: [
          Icon(scheme.icon, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(scheme.title)),
          if (scheme == current) const Icon(Icons.check, size: 18),
        ],
      ),
    ),
  ],
];

/// Desktop counterpart of [SchemeHeader], at the top of the side bar: the
/// scheme's icon opens the schemes and the account of the shown site.
class SchemeMenuButton extends StatelessWidget {
  const SchemeMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final ContentScheme scheme = schemeSetting.site.value;
      final LoginSite? site = scheme.loginSite;
      final String? account = _accountText(scheme);
      return PopupMenuButton<Object>(
        key: const Key('schemeMenu'),
        tooltip: '${scheme.title} · ${'switchScheme'.tr}',
        icon: Icon(scheme.icon, color: UIConfig.desktopLeftTabIconColor(context)),
        onSelected: (Object value) {
          if (value is ContentScheme) {
            switchScheme(scheme, value);
          } else if (site != null) {
            handleTapAccount(site);
          }
        },
        itemBuilder: (_) => [
          ..._schemeItems(scheme),
          if (account != null) ...[
            const PopupMenuDivider(),
            PopupMenuItem<Object>(
              value: 'account',
              enabled: site != null,
              child: Row(
                children: [
                  const Icon(Icons.account_circle_outlined, size: 20),
                  const SizedBox(width: 12),
                  Flexible(child: Text(account, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
          ],
        ],
      );
    });
  }
}

/// Drawer of the pages of their own (PDF): the scheme header and the
/// page's own entries.
class SchemeDrawer extends StatelessWidget {
  const SchemeDrawer({super.key, required this.current, this.children = const []});

  final ContentScheme current;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      width: 278,
      child: SafeArea(
        child: Column(
          children: [
            SchemeHeader(current: current),
            const Divider(height: 1),
            ...children,
          ],
        ),
      ),
    );
  }
}
