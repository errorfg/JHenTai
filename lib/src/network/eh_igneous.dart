import 'dart:io';

import 'package:dio/dio.dart';
import 'package:get/get_rx/get_rx.dart';
import 'package:jhentai/src/consts/eh_consts.dart';
import 'package:jhentai/src/exception/eh_site_exception.dart';
import 'package:jhentai/src/extension/dio_exception_extension.dart';
import 'package:jhentai/src/network/eh_ip_provider.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/eh_timeout_translator.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/setting/network_setting.dart';
import 'package:jhentai/src/utils/cookie_util.dart';

enum IgneousResult {
  /// [IgneousRefresh.value] holds the new igneous.
  refreshed,

  /// ExHentai answered 'mystery': the account has no access.
  noAccess,
  failed,
}

class IgneousRefresh {
  final IgneousResult result;
  final String? value;
  final String? message;

  const IgneousRefresh(this.result, {this.value, this.message});
}

IgneousRefresher igneousRefresher = IgneousRefresher();

/// Gets an igneous for this device. ExHentai gives each session its own, so
/// the request carries only the account's cookies (no igneous), and the
/// answer is this device's.
class IgneousRefresher {
  Dio? _dio;

  Future<IgneousRefresh> refresh({required int ipbMemberId, required String ipbPassHash}) async {
    _initDio();
    try {
      Response response = await _dio!.request(
        EHConsts.EXIndex,
        options: Options(headers: {
          'cookie': CookieUtil.parse2String([
            Cookie('ipb_member_id', ipbMemberId.toString()),
            Cookie('ipb_pass_hash', ipbPassHash),
          ])
        }),
      );

      log.info('Refresh igneous cookie, set-cookie: ${response.headers.value('set-cookie')}');

      List<String>? cookiePairs = response.headers.value('set-cookie')?.split(';');
      for (String cookiePair in cookiePairs ?? <String>[]) {
        List<String> parts = cookiePair.split('=');
        if (parts.length < 2 || parts[0].trim() != EHConsts.igneousCookieName) {
          continue;
        }
        String value = parts[1].trim();
        return value == 'mystery'
            ? const IgneousRefresh(IgneousResult.noAccess, message: 'Sad panda')
            : IgneousRefresh(IgneousResult.refreshed, value: value);
      }
      return const IgneousRefresh(IgneousResult.noAccess, message: 'Sad panda');
    } on DioException catch (e) {
      log.error('Refresh igneous failed: ${e.errorMsg}');
      return IgneousRefresh(IgneousResult.failed, message: e.errorMsg ?? '');
    } on EHSiteException catch (e) {
      log.error('Refresh igneous failed: ${e.message}');
      return IgneousRefresh(IgneousResult.failed, message: e.message);
    } catch (e) {
      log.error('Refresh igneous failed: $e');
      return IgneousRefresh(IgneousResult.failed, message: e.toString());
    }
  }

  void _initDio() {
    if (_dio != null) {
      return;
    }

    _dio = Dio(BaseOptions(
      connectTimeout: Duration(milliseconds: networkSetting.connectTimeout.value),
      receiveTimeout: Duration(milliseconds: networkSetting.receiveTimeout.value),
    ));

    EHIpProvider ehIpProvider = RoundRobinIpProvider(NetworkSetting.host2IPs);

    _dio!.interceptors.add(InterceptorsWrapper(
      onRequest: (RequestOptions options, RequestInterceptorHandler handler) {
        if (networkSetting.enableDomainFronting.isFalse) {
          handler.next(options);
          return;
        }

        String rawPath = options.path;
        String host = options.uri.host;
        if (!ehIpProvider.supports(host)) {
          handler.next(options);
          return;
        }

        String ip = ehIpProvider.nextIP(host);
        handler.next(options.copyWith(
          path: rawPath.replaceFirst(host, ip),
          headers: {...options.headers, 'host': host},
          extra: options.extra..[EHRequest.domainFrontingExtraKey] = {'host': host, 'ip': ip},
        ));
      },
      onError: (DioException e, ErrorInterceptorHandler handler) {
        if (!e.requestOptions.extra.containsKey(EHRequest.domainFrontingExtraKey)) {
          handler.next(e);
          return;
        }

        if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.badResponse || e.type == DioExceptionType.connectionError) {
          String host = e.requestOptions.extra[EHRequest.domainFrontingExtraKey]['host'];
          String ip = e.requestOptions.extra[EHRequest.domainFrontingExtraKey]['ip'];
          ehIpProvider.addUnavailableIp(host, ip);
          log.info('Refresh igneous, add unavailable host-ip: $host-$ip');
        }

        handler.next(e);
      },
    ));

    _dio!.interceptors.add(EHTimeoutTranslator());
  }
}
