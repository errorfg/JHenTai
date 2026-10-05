import 'package:flutter/material.dart';
import 'package:jhentai/src/pages/setting/account/login/login_page_state.dart';

/// What the app shows: a site, whose pages fill the navigation, or a
/// reading source with pages of its own (Komga, PDF).
enum ContentScheme {
  ehentai('E-Hentai', Icons.photo_library_outlined, LoginSite.eh),
  nhentai('nhentai', Icons.collections_bookmark_outlined, LoginSite.nh),
  wnacg('wnacg', Icons.auto_stories_outlined, null),
  jm('JM', Icons.local_library_outlined, LoginSite.jm),
  komga('Komga', Icons.dns_outlined, null),
  pdf('PDF', Icons.picture_as_pdf_outlined, null);

  final String title;
  final IconData icon;

  /// The account this scheme logs in with, if it has one.
  final LoginSite? loginSite;

  const ContentScheme(this.title, this.icon, this.loginSite);

  /// A site whose pages fill the app's navigation.
  bool get isSite => index <= jm.index;
}
