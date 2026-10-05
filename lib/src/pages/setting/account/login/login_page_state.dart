import 'package:flutter/cupertino.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

/// Sites with an account the app can use, in the order the login page
/// offers them.
enum LoginSite {
  eh('E-Hentai'),
  nh('nhentai'),
  jm('JM');

  final String title;

  const LoginSite(this.title);
}

enum LoginType { password, cookie, web }

enum CookieVerificationType { normal, webview, skip }

class LoginPageState {
  LoginSite site = LoginSite.eh;
  LoginType loginType = LoginType.password;
  CookieVerificationType cookieVerificationType = CookieVerificationType.normal;

  FocusNode passwordFocusNode = FocusNode();
  FocusNode ipbPassHashFocusNode = FocusNode();
  FocusNode igneousFocusNode = FocusNode();

  bool obscureText = true;

  String? userName;
  String? password;
  String? ipbMemberId;
  String? ipbPassHash;
  String? igneous;
  String? nhApiKey;

  LoadingState loginState = LoadingState.idle;
  LoadingState cookieLoginLoadingState = LoadingState.idle;
}
