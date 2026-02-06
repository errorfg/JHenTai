import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_socks_proxy/socks_proxy.dart';
import 'package:collection/collection.dart';
import 'package:get/get_rx/src/rx_types/rx_types.dart';
import 'package:get/get_rx/src/rx_workers/rx_workers.dart';
import 'package:get/get_utils/src/extensions/internacionalization.dart';
import 'package:get/get_utils/src/platform/platform.dart';
import 'package:intl/intl.dart';
import 'package:j_downloader/j_downloader.dart';
import 'package:jhentai/src/consts/eh_consts.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/exception/eh_site_exception.dart';
import 'package:jhentai/src/model/detail_page_info.dart';
import 'package:jhentai/src/model/eh_raw_tag.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_count.dart';
import 'package:jhentai/src/model/gallery_detail.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_thumbnail.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/model/gallery_comment.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/network/eh_ip_provider.dart';
import 'package:jhentai/src/network/eh_timeout_translator.dart';
import 'package:jhentai/src/pages/ranklist/ranklist_page_state.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/setting/eh_setting.dart';
import 'package:jhentai/src/setting/preference_setting.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/utils/eh_spider_parser.dart';
import 'package:jhentai/src/utils/proxy_util.dart';
import 'package:jhentai/src/utils/string_uril.dart';
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:path/path.dart';
import 'package:webview_flutter/webview_flutter.dart' show WebViewCookieManager;
import '../service/jh_service.dart';
import '../service/local_config_service.dart';
import '../setting/network_setting.dart';
import 'eh_cache_manager.dart';
import 'eh_cookie_manager.dart';

EHRequest ehRequest = EHRequest();

class EHRequest with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  late final Dio _dio;
  late final EHCookieManager _cookieManager;
  late final EHCacheManager _cacheManager;
  late final EHIpProvider _ehIpProvider;
  late final String systemProxyAddress;

  static const String _nhApiBase = 'https://nhentai.net/api';
  static const int _nhThumbnailsPerPage = 40;
  final Map<int, _NHentaiGalleryCache> _nhGalleryCache = {};

  List<Cookie> get cookies => List.unmodifiable(_cookieManager.cookies);

  static const String domainFrontingExtraKey = 'JHDF';

  @override
  List<JHLifeCircleBean> get initDependencies =>
      super.initDependencies..addAll([networkSetting, ehSetting]);

  @override
  Future<void> doInitBean() async {
    _dio = Dio(BaseOptions(
      connectTimeout:
          Duration(milliseconds: networkSetting.connectTimeout.value),
      receiveTimeout:
          Duration(milliseconds: networkSetting.receiveTimeout.value),
    ));

    systemProxyAddress = await getSystemProxyAddress();
    await _initProxy();

    await _initCookieManager();

    _initCacheManager();

    _initDomainFronting();
    _initCertificateForAndroidWithOldVersion();

    _ehIpProvider = RoundRobinIpProvider(NetworkSetting.host2IPs);

    _initTimeOutTranslator();

    ever(ehSetting.site, (_) {
      _cookieManager.removeCookies(['sp']);
    });
    ever(networkSetting.connectTimeout, (_) {
      setConnectTimeout(networkSetting.connectTimeout.value);
    });
    ever(networkSetting.receiveTimeout, (_) {
      setReceiveTimeout(networkSetting.receiveTimeout.value);
    });
  }

  @override
  Future<void> doAfterBeanReady() async {}

  Future<void> _initProxy() async {
    SocksProxy.initProxy(
      onCreate: (client) =>
          client.badCertificateCallback = (_, String host, __) {
        return networkSetting.allIPs.contains(host);
      },
      findProxy: await findProxySettingFunc(() => systemProxyAddress),
    );
  }

  Future<void> _initCookieManager() async {
    _cookieManager = EHCookieManager(localConfigService);
    await _cookieManager.initCookies();
    _dio.interceptors.add(_cookieManager);
  }

  void _initCacheManager() {
    _cacheManager = EHCacheManager(
      options: CacheOptions(
        policy: CachePolicy.disable,
        expire: networkSetting.pageCacheMaxAge.value,
        store: SqliteCacheStore(appDb: appDb),
      ),
    );
    _dio.interceptors.add(_cacheManager);
  }

  void _initDomainFronting() {
    /// domain fronting interceptor
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (RequestOptions options, RequestInterceptorHandler handler) {
        if (networkSetting.enableDomainFronting.isFalse) {
          handler.next(options);
          return;
        }

        String rawPath = options.path;
        String host = options.uri.host;
        if (!_ehIpProvider.supports(host)) {
          handler.next(options);
          return;
        }

        String ip = _ehIpProvider.nextIP(host);
        handler.next(options.copyWith(
          path: rawPath.replaceFirst(host, ip),
          headers: {...options.headers, 'host': host},
          extra: options.extra
            ..[domainFrontingExtraKey] = {'host': host, 'ip': ip},
        ));
      },
      onError: (DioException e, ErrorInterceptorHandler handler) {
        if (!e.requestOptions.extra.containsKey(domainFrontingExtraKey)) {
          handler.next(e);
          return;
        }

        if (e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.badResponse ||
            e.type == DioExceptionType.connectionError) {
          String host = e.requestOptions.extra[domainFrontingExtraKey]['host'];
          String ip = e.requestOptions.extra[domainFrontingExtraKey]['ip'];
          _ehIpProvider.addUnavailableIp(host, ip);
          log.info('Add unavailable host-ip: $host-$ip');
        }

        handler.next(e);
      },
    ));
  }

  /// https://github.com/dart-lang/io/issues/83
  void _initCertificateForAndroidWithOldVersion() {
    if (GetPlatform.isAndroid) {
      const isrgRootX1 = '''-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4
WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu
ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY
MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc
h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+
0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U
A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW
T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH
B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC
B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv
KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn
OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn
jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw
qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI
rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV
HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq
hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL
ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ
3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK
NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5
ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur
TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC
jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc
oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq
4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA
mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d
emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=
-----END CERTIFICATE-----
''';
      SecurityContext.defaultContext.setTrustedCertificatesBytes(
          Uint8List.fromList(isrgRootX1.codeUnits));
    }
  }

  void _initTimeOutTranslator() {
    _dio.interceptors.add(EHTimeoutTranslator());
  }

  Future<void> storeEHCookies(List<Cookie> cookies) {
    return _cookieManager.storeEHCookies(cookies);
  }

  Future<bool> removeAllCookies() {
    return _cookieManager.removeAllCookies();
  }

  Future<void> removeCacheByUrl(String url) {
    return _cacheManager.removeCacheByUrl(url);
  }

  Future<void> removeCacheByGalleryUrlAndPage(
      String galleryUrl, int pageIndex) {
    Uri uri = Uri.parse(galleryUrl);
    uri = uri.replace(queryParameters: {'p': pageIndex.toString()});

    List<Future> futures = [];
    futures.add(removeCacheByUrlPrefix(uri.toString()));

    NetworkSetting.host2IPs[uri.host]?.forEach((ip) {
      futures.add(removeCacheByUrlPrefix(uri.replace(host: ip).toString()));
    });

    return Future.wait(futures);
  }

  Future<void> removeCacheByUrlPrefix(String url) {
    return _cacheManager.removeCacheByUrlPrefix(url);
  }

  Future<void> removeAllCache() {
    return _cacheManager.removeAllCache();
  }

  ProxyConfig? currentProxyConfig() {
    switch (networkSetting.proxyType.value) {
      case JProxyType.system:
        if (systemProxyAddress.trim().isEmpty) {
          return null;
        }
        return ProxyConfig(
          type: ProxyType.http,
          address: systemProxyAddress,
        );
      case JProxyType.http:
        return ProxyConfig(
          type: ProxyType.http,
          address: networkSetting.proxyAddress.value,
          username: networkSetting.proxyUsername.value,
          password: networkSetting.proxyPassword.value,
        );
      case JProxyType.socks5:
        return ProxyConfig(
          type: ProxyType.socks5,
          address: networkSetting.proxyAddress.value,
          username: networkSetting.proxyUsername.value,
          password: networkSetting.proxyPassword.value,
        );
      case JProxyType.socks4:
        return ProxyConfig(
          type: ProxyType.socks4,
          address: networkSetting.proxyAddress.value,
          username: networkSetting.proxyUsername.value,
          password: networkSetting.proxyPassword.value,
        );
      case JProxyType.direct:
        return ProxyConfig(
          type: ProxyType.direct,
          address: '',
        );
    }
  }

  void setConnectTimeout(int connectTimeout) {
    _dio.options.connectTimeout = Duration(milliseconds: connectTimeout);
  }

  void setReceiveTimeout(int receiveTimeout) {
    _dio.options.receiveTimeout = Duration(milliseconds: receiveTimeout);
  }

  Future<T> requestLogin<T>(
      String userName, String passWord, HtmlParser<T> parser) async {
    Response response = await _postWithErrorHandler(
      EHConsts.EForums,
      options: Options(contentType: Headers.formUrlEncodedContentType),
      queryParameters: {'act': 'Login', 'CODE': '01'},
      data: {
        'referer': 'https://forums.e-hentai.org/index.php?',
        'b': '',
        'bt': '',
        'UserName': userName,
        'PassWord': passWord,
        'CookieDate': 365,
      },
    );
    return _parseResponse(response, parser);
  }

  Future<void> requestLogout() async {
    await removeAllCookies();
    await userSetting.clearBeanConfig();
    if (GetPlatform.isWindows || GetPlatform.isLinux) {
      Directory directory = Directory(join(pathService.getVisibleDir().path,
          EHConsts.desktopWebviewDirectoryName));
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } else {
      await WebViewCookieManager().clearCookies();
    }
  }

  Future<T> requestHomePage<T>({HtmlParser<T>? parser}) async {
    Response response = await _getWithErrorHandler(EHConsts.EHome);
    return _parseResponse(response, parser);
  }

  Future<T> requestNews<T>(HtmlParser<T> parser) async {
    Response response = await _getWithErrorHandler(EHConsts.ENews);
    return _parseResponse(response, parser);
  }

  Future<T> requestForum<T>(int ipbMemberId, HtmlParser<T> parser) async {
    Response response = await _getWithErrorHandler(
      EHConsts.EForums,
      queryParameters: {
        'showuser': ipbMemberId,
      },
    );
    return _parseResponse(response, parser);
  }

  /// [url]: used for file search
  Future<T> requestGalleryPage<T>({
    String? url,
    String? prevGid,
    String? nextGid,
    DateTime? seek,
    SearchConfig? searchConfig,
    required HtmlParser<T> parser,
  }) async {
    if (_shouldUseNhSearch(url: url, searchConfig: searchConfig)) {
      return _requestNhGalleryPage(
        url: url,
        prevGid: prevGid,
        nextGid: nextGid,
        searchConfig: searchConfig,
      );
    }

    Response response = await _getWithErrorHandler(
      url ?? searchConfig!.toPath(),
      queryParameters: {
        if (prevGid != null) 'prev': prevGid,
        if (nextGid != null) 'next': nextGid,
        if (seek != null) 'seek': DateFormat('yyyy-MM-dd').format(seek),
        ...?searchConfig?.toQueryParameters(),
      },
    );
    return _parseResponse(response, parser);
  }

  Future<T> requestDetailPage<T>({
    required String galleryUrl,
    int thumbnailsPageIndex = 0,
    bool useCacheIfAvailable = true,
    CancelToken? cancelToken,
    required HtmlParser<T> parser,
  }) async {
    if (GalleryUrl.tryParse(galleryUrl)?.isNH == true ||
        _isNhentaiUrl(galleryUrl)) {
      return _requestNhDetailPage(
        galleryUrl: galleryUrl,
        thumbnailsPageIndex: thumbnailsPageIndex,
        parser: parser,
      );
    }

    Response response = await _getWithErrorHandler(
      galleryUrl,
      queryParameters: {
        'p': thumbnailsPageIndex,

        /// show all comments
        'hc': preferenceSetting.showAllComments.isTrue ? 1 : 0,
      },
      cancelToken: cancelToken,
      options: useCacheIfAvailable
          ? CacheOptions.cacheOptions.toOptions()
          : CacheOptions.noCacheOptions.toOptions(),
    );
    return _parseResponse(response, parser);
  }

  Future<T> requestGalleryMetadata<T>({
    required int gid,
    required String token,
    required HtmlParser<T> parser,
  }) async {
    Response response = await _postWithErrorHandler(
      EHConsts.EHApi,
      options: Options(contentType: Headers.jsonContentType),
      data: {
        'method': 'gdata',
        'gidlist': [
          [gid, token]
        ],
        "namespace": 1,
      },
    );
    return _parseResponse(response, parser);
  }

  Future<T> requestGalleryMetadatas<T>({
    required List<({int gid, String token})> list,
    required HtmlParser<T> parser,
  }) async {
    Response response = await _postWithErrorHandler(
      EHConsts.EHApi,
      options: Options(contentType: Headers.jsonContentType),
      data: {
        'method': 'gdata',
        'gidlist': list.map((item) => [item.gid, item.token]).toList(),
        "namespace": 1,
      },
    );
    return _parseResponse(response, parser);
  }

  Future<T> requestRanklistPage<T>(
      {required RanklistType ranklistType,
      required int pageNo,
      required HtmlParser<T> parser}) async {
    int tl;

    switch (ranklistType) {
      case RanklistType.day:
        tl = 15;
        break;
      case RanklistType.month:
        tl = 13;
        break;
      case RanklistType.year:
        tl = 12;
        break;
      case RanklistType.allTime:
        tl = 11;
        break;
      default:
        tl = 15;
    }

    Response response =
        await _getWithErrorHandler('${EHConsts.ERanklist}?tl=$tl&p=$pageNo');
    return _parseResponse(response, parser);
  }

  Future<T> requestSubmitRating<T>(int gid, String token, int apiuid,
      String apikey, int rating, HtmlParser<T> parser) async {
    Response response = await _postWithErrorHandler(
      EHConsts.EApi,
      data: {
        'apikey': apikey,
        'apiuid': apiuid,
        'gid': gid,
        'method': "rategallery",
        'rating': rating,
        'token': token,
      },
    );
    return _parseResponse(response, parser);
  }

  Future<T> requestPopupPage<T>(
      int gid, String token, String act, HtmlParser<T> parser) async {
    /// eg: ?gid=2165080&t=725f6a7a58&act=addfav
    Response response = await _getWithErrorHandler(
      EHConsts.EPopup,
      queryParameters: {
        'gid': gid,
        't': token,
        'act': act,
      },
    );
    return _parseResponse(response, parser);
  }

  Future<T> requestFavoritePage<T>(HtmlParser<T> parser) async {
    Response response = await _getWithErrorHandler(EHConsts.EFavorite);

    return _parseResponse(response, parser);
  }

  Future<T> requestChangeFavoriteSortOrder<T>(FavoriteSortOrder sortOrder,
      {HtmlParser<T>? parser}) async {
    Response response = await _getWithErrorHandler(
      EHConsts.EFavorite,
      queryParameters: {
        'inline_set':
            sortOrder == FavoriteSortOrder.publishedTime ? 'fs_p' : 'fs_f',
      },
    );

    return _parseResponse(response, parser);
  }

  /// favcat: the favorite tag index
  Future<T> requestAddFavorite<T>(
      int gid, String token, int favcat, String note,
      {HtmlParser<T>? parser}) async {
    /// eg: ?gid=2165080&t=725f6a7a58&act=addfav
    Response response = await _postWithErrorHandler(
      EHConsts.EPopup,
      options: Options(contentType: Headers.formUrlEncodedContentType),
      queryParameters: {
        'gid': gid,
        't': token,
        'act': 'addfav',
      },
      data: {
        'favcat': favcat,
        'favnote': note,
        'apply': 'Add to Favorites',
        'update': 1,
      },
    );
    return _parseResponse(response, parser);
  }

  Future<T> requestRemoveFavorite<T>(int gid, String token,
      {HtmlParser<T>? parser}) async {
    /// eg: ?gid=2165080&t=725f6a7a58&act=addfav
    Response response = await _postWithErrorHandler(
      EHConsts.EPopup,
      options: Options(contentType: Headers.formUrlEncodedContentType),
      queryParameters: {
        'gid': gid,
        't': token,
        'act': 'addfav',
      },
      data: {
        'favcat': 'favdel',
        'favnote': '',
        'apply': 'Apply Changes',
        'update': 1,
      },
    );
    return _parseResponse(response, parser);
  }

  Future<T> requestImagePage<T>(
    String href, {
    String? reloadKey,
    CancelToken? cancelToken,
    bool useCacheIfAvailable = true,
    required HtmlParser<T> parser,
  }) async {
    if (href.startsWith('nh://') || _isNhentaiUrl(href)) {
      return _requestNhImagePage(
        href: href,
        parser: parser,
      );
    }

    Response response = await _getWithErrorHandler(
      href,
      queryParameters: {
        if (reloadKey != null) 'nl': reloadKey,
      },
      cancelToken: cancelToken,
      options: useCacheIfAvailable
          ? CacheOptions.cacheOptionsIgnoreParams.toOptions()
          : CacheOptions.noCacheOptionsIgnoreParams.toOptions(),
    );
    return _parseResponse(response, parser);
  }

  Future<T> requestTorrentPage<T>(
      int gid, String token, HtmlParser<T> parser) async {
    Response response = await _getWithErrorHandler(
      EHConsts.ETorrent,
      queryParameters: {
        'gid': gid,
        't': token,
      },
      options: CacheOptions.cacheOptions.toOptions(),
    );
    return _parseResponse(response, parser);
  }

  Future<T> requestSettingPage<T>(HtmlParser<T> parser) async {
    Response response = await _getWithErrorHandler(EHConsts.EUconfig);
    return _parseResponse(response, parser);
  }

  Future<T> createProfile<T>({HtmlParser<T>? parser}) async {
    Response response = await _postWithErrorHandler(
      EHConsts.EUconfig,
      options: Options(contentType: Headers.formUrlEncodedContentType),
      data: {
        'profile_action': 'create',
        'profile_name': 'JHenTai',
        'profile_set': '616',
      },
    );
    return _parseResponse(response, parser);
  }

  Future<T> requestMyTagsPage<T>(
      {int tagSetNo = 1, required HtmlParser<T> parser}) async {
    Response response = await _getWithErrorHandler(
      EHConsts.EMyTags,
      queryParameters: {'tagset': tagSetNo},
    );
    return _parseResponse(response, parser);
  }

  Future<T> requestStatPage<T>(
      {required int gid,
      required String token,
      required HtmlParser<T> parser}) async {
    Response response = await _getWithErrorHandler(
      '${EHConsts.EStat}?gid=$gid&t=$token',
      options: CacheOptions.cacheOptions.toOptions(),
    );
    return _parseResponse(response, parser);
  }

  Future<T> requestAddWatchedTag<T>({
    required String tag,
    String? tagColor,
    required int tagWeight,
    required bool watch,
    required bool hidden,
    int tagSetNo = 1,
    HtmlParser<T>? parser,
  }) async {
    Map<String, dynamic> data = {
      'usertag_action': "add",
      'tagname_new': tag,
      'tagcolor_new': tagColor ?? "",
      'usertag_target': 0,
      'tagweight_new': tagWeight,
    };

    if (hidden) {
      data['taghide_new'] = 'on';
    }
    if (watch) {
      data['tagwatch_new'] = 'on';
    }

    Response response;
    try {
      response = await _postWithErrorHandler(
        EHConsts.EMyTags,
        options: Options(contentType: Headers.formUrlEncodedContentType),
        queryParameters: {'tagset': tagSetNo},
        data: data,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 302) {
        response = e.response!;
      } else {
        rethrow;
      }
    }

    return _parseResponse(response, parser);
  }

  Future<T> requestDeleteWatchedTag<T>(
      {required int watchedTagId,
      int tagSetNo = 1,
      HtmlParser<T>? parser}) async {
    Response response;
    try {
      response = await _postWithErrorHandler(
        EHConsts.EMyTags,
        options: Options(contentType: Headers.formUrlEncodedContentType),
        queryParameters: {'tagset': tagSetNo},
        data: {
          'usertag_action': 'mass',
          'tagname_new': '',
          'tagcolor_new': '',
          'usertag_target': 0,
          'tagweight_new': 10,
          'modify_usertags[]': watchedTagId,
        },
      );
    } on DioException catch (e) {
      if (e.response?.statusCode != 302) {
        rethrow;
      }
      response = e.response!;
    }

    return _parseResponse(response, parser);
  }

  Future<T> requestUpdateTagSet<T>({
    required int tagSetNo,
    required bool enable,
    required String? color,
    HtmlParser<T>? parser,
  }) async {
    Response response;
    try {
      response = await _postWithErrorHandler(
        EHConsts.EMyTags,
        options: Options(contentType: Headers.formUrlEncodedContentType),
        queryParameters: {'tagset': tagSetNo},
        data: {
          'tagset_action': 'update',
          'tagset_name': '',
          if (enable) 'tagset_enable': 'on',
          'tagset_color': color ?? '',
        },
      );
    } on DioException catch (e) {
      if (e.response?.statusCode != 302) {
        rethrow;
      }
      response = e.response!;
    }

    return _parseResponse(response, parser);
  }

  Future<T> requestUpdateWatchedTag<T>({
    required int apiuid,
    required String apikey,
    required int tagId,
    required String? tagColor,
    required int tagWeight,
    required bool watch,
    required bool hidden,
    HtmlParser<T>? parser,
  }) async {
    Response response = await _postWithErrorHandler(
      EHConsts.EHApi,
      options: Options(contentType: Headers.jsonContentType),
      data: {
        'method': "setusertag",
        'apiuid': apiuid,
        'apikey': apikey,
        'tagcolor': tagColor ?? "",
        'taghide': hidden ? 1 : 0,
        'tagwatch': watch ? 1 : 0,
        'tagid': tagId,
        'tagweight': tagWeight.toString(),
      },
    );
    return _parseResponse(response, parser);
  }

  Future<T> download<T>({
    required String url,
    required String path,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    bool appendMode = false,
    bool preserveHeaderCase = true,
    int? receiveTimeout,
    String? range,
    bool deleteOnError = true,
    HtmlParser<T>? parser,
  }) async {
    Response response = await _dio.download(
      url,
      path,
      onReceiveProgress: onReceiveProgress,
      shouldAppendFile: appendMode,
      cancelToken: cancelToken,
      deleteOnError: deleteOnError,
      options: Options(
        preserveHeaderCase: preserveHeaderCase,
        headers: range == null ? null : {'Range': range},
        receiveTimeout: Duration(milliseconds: receiveTimeout ?? 0),
      ),
    );

    if (parser == null) {
      return response as T;
    }
    return parser(response.headers, response.data);
  }

  Future<T> voteTag<T>(int gid, String token, int apiuid, String apikey,
      String tag, bool isVotingUp,
      {HtmlParser<T>? parser}) async {
    Response response = await _postWithErrorHandler(
      EHConsts.EApi,
      data: {
        'apikey': apikey,
        'apiuid': apiuid,
        'gid': gid,
        'method': "taggallery",
        'token': token,
        'vote': isVotingUp ? 1 : -1,
        'tags': tag,
      },
    );
    return _parseResponse(response, parser);
  }

  Future<T> voteComment<T>(int gid, String token, int apiuid, String apikey,
      int commentId, bool isVotingUp,
      {HtmlParser<T>? parser}) async {
    Response response = await _postWithErrorHandler(
      EHConsts.EApi,
      data: {
        'apikey': apikey,
        'apiuid': apiuid,
        'gid': gid,
        'method': "votecomment",
        'token': token,
        'comment_vote': isVotingUp ? 1 : -1,
        'comment_id': commentId,
      },
    );
    return _parseResponse(response, parser);
  }

  Future<T> requestTagSuggestion<T>(
      String keyword, HtmlParser<T> parser) async {
    if (_isNhKeywordSearch(keyword)) {
      return <EHRawTag>[] as T;
    }

    Response response = await _postWithErrorHandler(
      EHConsts.EApi,
      data: {
        'method': "tagsuggest",
        'text': keyword,
      },
    );
    return _parseResponse(response, parser);
  }

  Future<T> requestSendComment<T>({
    required String galleryUrl,
    required String content,
    required HtmlParser<T> parser,
  }) async {
    Response response = await _postWithErrorHandler(
      galleryUrl,
      options: Options(contentType: Headers.formUrlEncodedContentType),
      data: {
        'commenttext_new': content,
      },
    );
    return _parseResponse(response, parser);
  }

  Future<T> requestUpdateComment<T>({
    required String galleryUrl,
    required String content,
    required int commentId,
    required HtmlParser<T> parser,
  }) async {
    Response response = await _postWithErrorHandler(
      galleryUrl,
      options: Options(contentType: Headers.formUrlEncodedContentType),
      data: {
        'edit_comment': commentId,
        'commenttext_edit': content,
      },
    );
    return _parseResponse(response, parser);
  }

  Future<T> requestLookup<T>({
    required String imagePath,
    required String imageName,
    required HtmlParser<T> parser,
  }) async {
    try {
      await _postWithErrorHandler(
        EHConsts.ELookup,
        data: FormData.fromMap({
          'sfile': MultipartFile.fromFileSync(
            imagePath,
            filename: imageName,
            contentType: MediaType.parse('application/octet-stream'),
          ),
          'f_sfile': "File Search",
          'fs_similar': 'on',
          'fs_exp': 'on',
        }),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode != 302) {
        rethrow;
      }

      return _parseResponse(e.response!, parser);
    }

    throw EHSiteException(
        message: 'Look up response error',
        type: EHSiteExceptionType.internalError);
  }

  Future<T> requestUnlockArchive<T>({
    required String url,
    required bool isOriginal,
    CancelToken? cancelToken,
    HtmlParser<T>? parser,
  }) async {
    Response response = await _postWithErrorHandler(
      url,
      data: FormData.fromMap({
        'dltype': isOriginal ? 'org' : 'res',
        'dlcheck': isOriginal
            ? 'Download Original Archive'
            : 'Download Resample Archive',
      }),
      cancelToken: cancelToken,
    );

    return _parseResponse(response, parser);
  }

  Future<T> requestCancelArchive<T>(
      {required String url,
      CancelToken? cancelToken,
      HtmlParser<T>? parser}) async {
    Response response = await _postWithErrorHandler(
      url,
      cancelToken: cancelToken,
      data: FormData.fromMap({'invalidate_sessions': 1}),
    );

    return _parseResponse(response, parser);
  }

  Future<T> requestHHDownload<T>({
    required String url,
    required String resolution,
    HtmlParser<T>? parser,
  }) async {
    Response response = await _postWithErrorHandler(
      url,
      data: FormData.fromMap({'hathdl_xres': resolution}),
    );

    return _parseResponse(response, parser);
  }

  Future<T> requestExchangePage<T>({HtmlParser<T>? parser}) async {
    Response response = await _getWithErrorHandler(EHConsts.EExchange);

    return _parseResponse(response, parser);
  }

  Future<T> requestResetImageLimit<T>({HtmlParser<T>? parser}) async {
    Response response = await _postWithErrorHandler(
      EHConsts.EHome,
      data: FormData.fromMap({
        'reset_imagelimit': 'Reset Limit',
      }),
    );

    return _parseResponse(response, parser);
  }

  bool _isNhentaiUrl(String? url) {
    if (url == null || url.isEmpty) {
      return false;
    }
    if (url.startsWith('nh://')) {
      return true;
    }
    Uri? uri = Uri.tryParse(url);
    if (uri == null) {
      return false;
    }
    String host = uri.host.toLowerCase();
    return host == 'nhentai.net' ||
        host == 'www.nhentai.net' ||
        host.endsWith('.nhentai.net');
  }

  bool _shouldUseNhSearch({String? url, SearchConfig? searchConfig}) {
    if (_isNhentaiUrl(url)) {
      return true;
    }

    if (searchConfig == null) {
      return false;
    }

    if (searchConfig.searchType != SearchType.gallery) {
      return false;
    }

    if (_isNhKeywordSearch(searchConfig.keyword)) {
      return true;
    }

    return false;
  }

  bool _isNhKeywordSearch(String? keyword) {
    if (keyword == null) {
      return false;
    }

    String normalized = keyword.trimLeft().toLowerCase();
    return normalized.startsWith('nh:');
  }

  Future<T> _requestNhGalleryPage<T>({
    String? url,
    String? prevGid,
    String? nextGid,
    SearchConfig? searchConfig,
  }) async {
    SearchType? searchType = searchConfig?.searchType;
    if (searchType == SearchType.favorite || searchType == SearchType.watched) {
      return GalleryPageInfo(gallerys: []) as T;
    }

    int pageNo = int.tryParse(nextGid ?? prevGid ?? '') ?? 1;
    if (pageNo < 1) {
      pageNo = 1;
    }

    bool isPopularRequest = searchType == SearchType.popular ||
        (url?.contains('/popular') ?? false);
    String query = _buildNhQuery(searchConfig);

    Map<String, dynamic> body;
    if (isPopularRequest) {
      body = await _requestNhApiSearch(
        query: query.isEmpty ? '*' : query,
        sort: 'popular-week',
        pageNo: pageNo,
      );
    } else if (query.isEmpty || query == '*') {
      body = await _requestNhApiAll(pageNo: pageNo);
    } else {
      body = await _requestNhApiSearch(
        query: query,
        sort: 'date',
        pageNo: pageNo,
      );
    }

    List<Gallery> gallerys = _parseNhGalleryList(body);
    int totalPages = _tryParseInt(body['num_pages']) ?? 0;
    int? perPage = _tryParseInt(body['per_page']);

    String? next;
    if (totalPages > 0) {
      next = pageNo < totalPages ? (pageNo + 1).toString() : null;
    } else {
      next = gallerys.isEmpty ? null : (pageNo + 1).toString();
    }

    GalleryCount? totalCount;
    if (totalPages > 0 && perPage != null) {
      totalCount = GalleryCount(
        type: GalleryCountType.accurate,
        count: (totalPages * perPage).toString(),
      );
    }

    return GalleryPageInfo(
      gallerys: gallerys,
      totalCount: totalCount,
      prevGid: pageNo > 1 ? (pageNo - 1).toString() : null,
      nextGid: next,
    ) as T;
  }

  Future<T> _requestNhDetailPage<T>({
    required String galleryUrl,
    int thumbnailsPageIndex = 0,
    required HtmlParser<T> parser,
  }) async {
    GalleryUrl parsedUrl = GalleryUrl.parse(galleryUrl);
    _NHentaiGalleryCache cache = await _getNhGalleryCache(parsedUrl.gid);

    if (parser == EHSpiderParser.detailPage2GalleryAndDetailAndApikey) {
      return (
        galleryDetails: _parseNhGalleryDetail(
          cache.rawGallery,
          galleryUrl: cache.galleryUrl,
          pageInfos: cache.pageInfos,
          mediaId: cache.mediaId,
        ),
        apikey: '',
      ) as T;
    }

    if (parser == EHSpiderParser.detailPage2Thumbnails) {
      return _buildNhThumbnails(cache, thumbnailsPageIndex) as T;
    }

    if (parser == EHSpiderParser.detailPage2RangeAndThumbnails) {
      return _buildNhDetailPageInfo(cache, thumbnailsPageIndex) as T;
    }

    if (parser == EHSpiderParser.detailPage2Comments) {
      return <GalleryComment>[] as T;
    }

    throw EHSiteException(
      type: EHSiteExceptionType.internalError,
      message: 'Unsupported nhentai detail parser',
      shouldPauseAllDownloadTasks: false,
    );
  }

  Future<T> _requestNhImagePage<T>({
    required String href,
    required HtmlParser<T> parser,
  }) async {
    if (_isNhentaiUrl(href) && parser == EHSpiderParser.imagePage2GalleryUrl) {
      return GalleryUrl.parse(href) as T;
    }

    RegExpMatch? match = RegExp(r'^nh://(\d+)/(\d+)$').firstMatch(href);
    if (match == null) {
      throw EHSiteException(
        type: EHSiteExceptionType.internalError,
        message: 'Invalid nhentai image url',
        shouldPauseAllDownloadTasks: false,
      );
    }

    int gid = int.parse(match.group(1)!);
    int pageNo = int.parse(match.group(2)!);
    _NHentaiGalleryCache cache = await _getNhGalleryCache(gid);
    if (pageNo < 1 || pageNo > cache.pageInfos.length) {
      throw EHSiteException(
        type: EHSiteExceptionType.internalError,
        message: 'Invalid nhentai image index',
        shouldPauseAllDownloadTasks: false,
      );
    }

    _NHentaiImageInfo imageInfo = cache.pageInfos[pageNo - 1];
    String imageUrl =
        _nhBuildPageImageUrl(cache.mediaId, pageNo, imageInfo.type);
    GalleryImage image = GalleryImage(
      url: imageUrl,
      height: imageInfo.height?.toDouble(),
      width: imageInfo.width?.toDouble(),
      originalImageUrl: imageUrl,
      originalImageHeight: imageInfo.height?.toDouble(),
      originalImageWidth: imageInfo.width?.toDouble(),
      imageHash: '${cache.mediaId}-$pageNo',
    );

    if (parser == EHSpiderParser.imagePage2GalleryImage ||
        parser == EHSpiderParser.imagePage2OriginalGalleryImage) {
      return image as T;
    }

    if (parser == EHSpiderParser.imagePage2GalleryUrl) {
      return cache.galleryUrl as T;
    }

    return image as T;
  }

  Future<Map<String, dynamic>> _requestNhApiAll({required int pageNo}) {
    return _requestNhApiJson(
      '/galleries/all',
      queryParameters: {'page': pageNo},
    );
  }

  Future<Map<String, dynamic>> _requestNhApiSearch({
    required String query,
    required String sort,
    required int pageNo,
  }) {
    return _requestNhApiJson(
      '/galleries/search',
      queryParameters: {
        'query': query,
        'sort': sort,
        'page': pageNo,
      },
    );
  }

  Future<Map<String, dynamic>> _requestNhApiGallery(int gid) {
    return _requestNhApiJson('/gallery/$gid');
  }

  Future<Map<String, dynamic>> _requestNhApiJson(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    Response response = await _getWithErrorHandler(
      '$_nhApiBase$path',
      queryParameters: queryParameters,
    );

    dynamic data = response.data;
    if (data is String) {
      data = jsonDecode(data);
    }

    if (data is Map<String, dynamic>) {
      return data;
    }
    if (data is Map) {
      return data.cast<String, dynamic>();
    }

    throw EHSiteException(
      type: EHSiteExceptionType.internalError,
      message: 'Unexpected nhentai response',
      shouldPauseAllDownloadTasks: false,
    );
  }

  Future<_NHentaiGalleryCache> _getNhGalleryCache(int gid) async {
    _NHentaiGalleryCache? cached = _nhGalleryCache[gid];
    if (cached != null) {
      return cached;
    }

    Map<String, dynamic> body = await _requestNhApiGallery(gid);
    _NHentaiGalleryCache cache = _cacheNhGallery(body);
    return cache;
  }

  _NHentaiGalleryCache _cacheNhGallery(Map<String, dynamic> item) {
    int gid = _parseInt(item['id']);
    String mediaId = item['media_id']?.toString() ?? '';
    List<_NHentaiImageInfo> pageInfos = _parseNhPageInfos(item);

    _NHentaiGalleryCache cache = _NHentaiGalleryCache(
      gid: gid,
      mediaId: mediaId,
      galleryUrl: GalleryUrl(
        isEH: true,
        isNH: true,
        gid: gid,
        token: 'nhentai',
      ),
      pageInfos: pageInfos,
      rawGallery: item,
    );
    _nhGalleryCache[gid] = cache;
    return cache;
  }

  List<Gallery> _parseNhGalleryList(Map<String, dynamic> body) {
    List<dynamic> items = (body['result'] as List?) ?? const [];

    return items.whereType<Map>().map((item) {
      Map<String, dynamic> typedItem = item.cast<String, dynamic>();
      _cacheNhGallery(typedItem);
      return _parseNhGallery(typedItem);
    }).toList();
  }

  Gallery _parseNhGallery(Map<String, dynamic> item) {
    int gid = _parseInt(item['id']);
    String mediaId = item['media_id']?.toString() ?? '';
    Map<String, dynamic> titleMap =
        ((item['title'] as Map?) ?? const {}).cast<String, dynamic>();
    String title = (titleMap['pretty'] ??
            titleMap['english'] ??
            titleMap['japanese'] ??
            '#$gid')
        .toString();

    Map<String, dynamic> imagesMap =
        ((item['images'] as Map?) ?? const {}).cast<String, dynamic>();
    Map<String, dynamic> coverMap =
        ((imagesMap['cover'] as Map?) ?? const {}).cast<String, dynamic>();
    String coverType = (coverMap['t'] ?? 'j').toString();

    LinkedHashMap<String, List<GalleryTag>> tags = _parseNhTagsMap(item);

    return Gallery(
      galleryUrl: GalleryUrl(
        isEH: true,
        isNH: true,
        gid: gid,
        token: 'nhentai',
      ),
      title: title,
      category: _findNhCategory(item),
      cover: GalleryImage(
        url: _nhBuildCoverUrl(mediaId, coverType),
        width: _tryParseInt(coverMap['w'])?.toDouble(),
        height: _tryParseInt(coverMap['h'])?.toDouble(),
      ),
      pageCount:
          _tryParseInt(item['num_pages']) ?? _parseNhPageInfos(item).length,
      rating: 0,
      hasRated: false,
      favoriteTagIndex: null,
      favoriteTagName: null,
      language: _findNhLanguage(item),
      uploader: item['scanlator']?.toString(),
      publishTime: DateTime.fromMillisecondsSinceEpoch(
              (_tryParseInt(item['upload_date']) ?? 0) * 1000,
              isUtc: true)
          .toString(),
      isExpunged: false,
      tags: tags,
    );
  }

  GalleryDetail _parseNhGalleryDetail(
    Map<String, dynamic> item, {
    required GalleryUrl galleryUrl,
    required List<_NHentaiImageInfo> pageInfos,
    required String mediaId,
  }) {
    Map<String, dynamic> titleMap =
        ((item['title'] as Map?) ?? const {}).cast<String, dynamic>();
    String rawTitle = (titleMap['english'] ??
            titleMap['pretty'] ??
            titleMap['japanese'] ??
            '#${galleryUrl.gid}')
        .toString();
    String? japaneseTitle = titleMap['japanese']?.toString();

    Map<String, dynamic> imagesMap =
        ((item['images'] as Map?) ?? const {}).cast<String, dynamic>();
    Map<String, dynamic> coverMap =
        ((imagesMap['cover'] as Map?) ?? const {}).cast<String, dynamic>();
    String coverType = (coverMap['t'] ?? 'j').toString();

    LinkedHashMap<String, List<GalleryTag>> tags = _parseNhTagsMap(item);
    int pageCount = _tryParseInt(item['num_pages']) ?? pageInfos.length;

    int thumbnailsPageCount =
        pageCount == 0 ? 1 : (pageCount / _nhThumbnailsPerPage).ceil();
    if (thumbnailsPageCount < 1) {
      thumbnailsPageCount = 1;
    }

    return GalleryDetail(
      galleryUrl: galleryUrl,
      rawTitle: rawTitle,
      japaneseTitle: japaneseTitle == null || japaneseTitle.trim().isEmpty
          ? null
          : japaneseTitle,
      category: _findNhCategory(item),
      cover: GalleryImage(
        url: _nhBuildCoverUrl(mediaId, coverType),
        width: _tryParseInt(coverMap['w'])?.toDouble(),
        height: _tryParseInt(coverMap['h'])?.toDouble(),
      ),
      pageCount: pageCount,
      rating: 0,
      realRating: 0,
      hasRated: false,
      ratingCount: 0,
      favoriteTagIndex: null,
      favoriteTagName: null,
      favoriteCount: _tryParseInt(item['num_favorites']) ?? 0,
      language: _findNhLanguage(item) ?? '',
      uploader: item['scanlator']?.toString(),
      publishTime: DateTime.fromMillisecondsSinceEpoch(
              (_tryParseInt(item['upload_date']) ?? 0) * 1000,
              isUtc: true)
          .toString(),
      isExpunged: false,
      tags: tags,
      size: '$pageCount pages',
      torrentCount: '0',
      torrentPageUrl: '',
      archivePageUrl: '',
      parentGalleryUrl: null,
      childrenGallerys: const [],
      comments: const [],
      thumbnails: _buildNhThumbnails(_nhGalleryCache[galleryUrl.gid]!, 0),
      thumbnailsPageCount: thumbnailsPageCount,
    );
  }

  String _buildNhQuery(SearchConfig? searchConfig) {
    if (searchConfig == null) {
      return '';
    }

    List<String> parts = [];
    String? keyword = _normalizeNhKeyword(searchConfig.keyword);
    if (keyword != null && keyword.isNotEmpty) {
      parts.add(keyword);
    }

    if (searchConfig.tags?.isNotEmpty ?? false) {
      for (TagData tag in searchConfig.tags!) {
        String key = tag.key.trim();
        if (key.isEmpty) {
          continue;
        }

        String namespace = tag.namespace.trim();
        if (namespace.isEmpty) {
          parts.add(key);
        } else {
          parts.add('$namespace:$key');
        }
      }
    }

    String? language = searchConfig.language?.trim();
    if (language != null && language.isNotEmpty) {
      parts.add('language:$language');
    }

    return parts.join(' ').trim();
  }

  String? _normalizeNhKeyword(String? rawKeyword) {
    if (rawKeyword == null) {
      return null;
    }

    String keyword = rawKeyword.trim();
    if (keyword.isEmpty) {
      return '';
    }

    if (_isNhKeywordSearch(keyword)) {
      keyword = keyword.trimLeft().substring(3).trim();
    }

    if (keyword.isEmpty) {
      return '';
    }

    List<String> tokens = [];
    Iterable<RegExpMatch> matches =
        RegExp(r'(\w+):"([^"]+)"|(\w+):(\S+)|"([^"]+)"|(\S+)')
            .allMatches(keyword);

    for (RegExpMatch match in matches) {
      String? namespace = match.group(1) ?? match.group(3);
      String? key = match.group(2) ?? match.group(4);
      String? plain = match.group(5) ?? match.group(6);

      if (namespace != null && key != null) {
        String normalizedKey = key.replaceAll('\$', '').trim();
        if (normalizedKey.isEmpty) {
          continue;
        }

        String ns = namespace.toLowerCase();
        if (ns == 'title') {
          tokens.add(normalizedKey);
          continue;
        }
        if (ns == 'uploader') {
          tokens.add('artist:$normalizedKey');
          continue;
        }

        tokens.add('$ns:$normalizedKey');
        continue;
      }

      if (plain != null && plain.trim().isNotEmpty) {
        tokens.add(plain.trim().replaceAll('\$', ''));
      }
    }

    if (tokens.isEmpty) {
      return keyword;
    }

    return tokens.join(' ').trim();
  }

  List<_NHentaiImageInfo> _parseNhPageInfos(Map<String, dynamic> item) {
    Map<String, dynamic> images =
        ((item['images'] as Map?) ?? const {}).cast<String, dynamic>();
    List<dynamic> pages = (images['pages'] as List?) ?? const [];
    return pages.whereType<Map>().map((raw) {
      Map<String, dynamic> page = raw.cast<String, dynamic>();
      return _NHentaiImageInfo(
        type: (page['t'] ?? 'j').toString(),
        width: _tryParseInt(page['w']),
        height: _tryParseInt(page['h']),
      );
    }).toList();
  }

  List<GalleryThumbnail> _buildNhThumbnails(
      _NHentaiGalleryCache cache, int thumbnailsPageIndex) {
    int imageCount = cache.pageInfos.length;
    if (imageCount == 0) {
      return const [];
    }

    int start = thumbnailsPageIndex * _nhThumbnailsPerPage;
    if (start < 0) {
      start = 0;
    }
    if (start >= imageCount) {
      return const [];
    }

    int end = start + _nhThumbnailsPerPage;
    if (end > imageCount) {
      end = imageCount;
    }

    List<GalleryThumbnail> thumbnails = [];
    for (int i = start; i < end; i++) {
      int pageNo = i + 1;
      _NHentaiImageInfo imageInfo = cache.pageInfos[i];
      thumbnails.add(GalleryThumbnail(
        href: 'nh://${cache.gid}/$pageNo',
        isLarge: true,
        thumbUrl:
            _nhBuildPageThumbnailUrl(cache.mediaId, pageNo, imageInfo.type),
        thumbWidth: imageInfo.width?.toDouble(),
        thumbHeight: imageInfo.height?.toDouble(),
        originImageHash: '${cache.mediaId}-$pageNo',
      ));
    }

    return thumbnails;
  }

  DetailPageInfo _buildNhDetailPageInfo(
      _NHentaiGalleryCache cache, int thumbnailsPageIndex) {
    int imageCount = cache.pageInfos.length;
    if (imageCount == 0) {
      return const DetailPageInfo(
        imageNoFrom: 0,
        imageNoTo: 0,
        imageCount: 0,
        currentPageNo: 1,
        pageCount: 1,
        thumbnails: [],
      );
    }

    int pageCount = (imageCount / _nhThumbnailsPerPage).ceil();
    if (pageCount < 1) {
      pageCount = 1;
    }

    int currentPageNo = thumbnailsPageIndex + 1;
    if (currentPageNo < 1) {
      currentPageNo = 1;
    }
    if (currentPageNo > pageCount) {
      currentPageNo = pageCount;
    }

    int imageNoFrom = (currentPageNo - 1) * _nhThumbnailsPerPage;
    int imageNoToExclusive = imageNoFrom + _nhThumbnailsPerPage;
    if (imageNoToExclusive > imageCount) {
      imageNoToExclusive = imageCount;
    }

    return DetailPageInfo(
      imageNoFrom: imageNoFrom,
      imageNoTo: imageNoToExclusive - 1,
      imageCount: imageCount,
      currentPageNo: currentPageNo,
      pageCount: pageCount,
      thumbnails: _buildNhThumbnails(cache, currentPageNo - 1),
    );
  }

  String _findNhCategory(Map<String, dynamic> item) {
    List<dynamic> tags = (item['tags'] as List?) ?? const [];
    Map? categoryTag = tags
        .whereType<Map>()
        .firstWhereOrNull((tag) => tag['type']?.toString() == 'category');
    String rawCategory = categoryTag?['name']?.toString() ?? 'manga';

    switch (rawCategory.toLowerCase()) {
      case 'artistcg':
      case 'artist cg':
        return 'Artist CG';
      case 'gamecg':
      case 'game cg':
        return 'Game CG';
      case 'imageset':
      case 'image set':
        return 'Image Set';
      case 'asianporn':
      case 'asian porn':
        return 'Asian Porn';
      case 'non-h':
      case 'nonh':
        return 'Non-H';
      case 'doujinshi':
        return 'Doujinshi';
      case 'manga':
        return 'Manga';
      case 'western':
        return 'Western';
      case 'cosplay':
        return 'Cosplay';
      case 'misc':
        return 'Misc';
      default:
        return rawCategory;
    }
  }

  String? _findNhLanguage(Map<String, dynamic> item) {
    List<dynamic> tags = (item['tags'] as List?) ?? const [];
    for (Map tag in tags.whereType<Map>()) {
      if (tag['type']?.toString() != 'language') {
        continue;
      }

      String language = tag['name']?.toString() ?? '';
      if (language.isEmpty || language == 'translated') {
        continue;
      }
      return language;
    }
    return null;
  }

  LinkedHashMap<String, List<GalleryTag>> _parseNhTagsMap(
      Map<String, dynamic> item) {
    LinkedHashMap<String, List<GalleryTag>> result = LinkedHashMap();
    List<dynamic> rawTags = (item['tags'] as List?) ?? const [];

    for (Map tagMap in rawTags.whereType<Map>()) {
      String name = tagMap['name']?.toString() ?? '';
      if (name.isEmpty) {
        continue;
      }

      String namespace =
          _normalizeNhTagNamespace(tagMap['type']?.toString() ?? 'tag');
      result.putIfAbsent(namespace, () => []).add(
            GalleryTag(
              tagData: TagData(
                namespace: namespace,
                key: name,
              ),
            ),
          );
    }

    return result;
  }

  String _normalizeNhTagNamespace(String rawType) {
    switch (rawType.toLowerCase()) {
      case 'parody':
      case 'character':
      case 'tag':
      case 'artist':
      case 'group':
      case 'language':
      case 'category':
        return rawType.toLowerCase();
      default:
        return 'tag';
    }
  }

  String _nhType2Ext(String type) {
    switch (type.toLowerCase()) {
      case 'j':
      case 'jpg':
      case 'jpeg':
        return 'jpg';
      case 'p':
      case 'png':
        return 'png';
      case 'g':
      case 'gif':
        return 'gif';
      case 'w':
      case 'webp':
        return 'webp';
      default:
        return 'jpg';
    }
  }

  String _nhBuildCoverUrl(String mediaId, String type) {
    return 'https://t.nhentai.net/galleries/$mediaId/cover.${_nhType2Ext(type)}';
  }

  String _nhBuildPageThumbnailUrl(String mediaId, int pageNo, String type) {
    return 'https://t.nhentai.net/galleries/$mediaId/${pageNo}t.${_nhType2Ext(type)}';
  }

  String _nhBuildPageImageUrl(String mediaId, int pageNo, String type) {
    return 'https://i.nhentai.net/galleries/$mediaId/$pageNo.${_nhType2Ext(type)}';
  }

  int _parseInt(dynamic value) {
    return _tryParseInt(value) ?? 0;
  }

  int? _tryParseInt(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value.toString());
  }

  Future<T> get<T>({
    required String url,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    Options? options,
    HtmlParser<T>? parser,
  }) async {
    Response response = await _getWithErrorHandler(
      url,
      cancelToken: cancelToken,
      queryParameters: queryParameters,
      options: options,
    );

    return _parseResponse(response, parser);
  }

  Future<T> post<T>({
    required String url,
    data,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    Options? options,
    HtmlParser<T>? parser,
  }) async {
    Response response = await _postWithErrorHandler(
      url,
      data: data,
      cancelToken: cancelToken,
      queryParameters: queryParameters,
      options: options,
    );

    return _parseResponse(response, parser);
  }

  Future<Response> head<T>(
      {required String url, CancelToken? cancelToken, Options? options}) {
    return _dio.head(
      url,
      cancelToken: cancelToken,
      options: options,
    );
  }

  Future<T> _parseResponse<T>(Response response, HtmlParser<T>? parser) async {
    if (parser == null) {
      return response as T;
    }
    return isolateService.run(
        (list) => parser(list[0], list[1]), [response.headers, response.data]);
  }

  Future<Response> _getWithErrorHandler<T>(
    String url, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) async {
    Response response;

    try {
      response = await _dio.get(
        url,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
        onReceiveProgress: onReceiveProgress,
      );
    } on DioException catch (e) {
      throw _convertExceptionIfGalleryDeleted(e);
    }

    try {
      _emitEHExceptionIfFailed(response);
    } on EHSiteException catch (_) {
      removeCacheByUrl(response.requestOptions.uri.toString());
      rethrow;
    }

    return response;
  }

  Future<Response> _postWithErrorHandler<T>(
    String url, {
    data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    Response response;
    try {
      response = await _dio.post(
        url,
        data: data,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
      );
    } on DioException catch (e) {
      throw _convertExceptionIfGalleryDeleted(e);
    }

    _emitEHExceptionIfFailed(response);

    return response;
  }

  Exception _convertExceptionIfGalleryDeleted(DioException e) {
    if (e.response?.statusCode == 404 &&
        networkSetting.allHostAndIPs.contains(e.requestOptions.uri.host)) {
      String? errMessage = EHSpiderParser.a404Page2GalleryDeletedHint(
          e.response!.headers, e.response!.data);
      if (!isEmptyOrNull(errMessage)) {
        return EHSiteException(
          type: EHSiteExceptionType.galleryDeleted,
          message: errMessage!,
          shouldPauseAllDownloadTasks: false,
        );
      }
    }

    return e;
  }

  void _emitEHExceptionIfFailed(Response response) {
    if (!networkSetting.allHostAndIPs
        .contains(response.requestOptions.uri.host)) {
      return;
    }

    if (response.data is String) {
      String data = response.data.toString();

      if (data.isEmpty) {
        throw EHSiteException(
            type: EHSiteExceptionType.blankBody,
            message: 'sadPanda'.tr,
            referLink: 'sadPandaReferLink'.tr);
      }

      if (data.startsWith('Your IP address')) {
        throw EHSiteException(
            type: EHSiteExceptionType.banned, message: response.data);
      }
      if (data.startsWith('This IP address')) {
        throw EHSiteException(
            type: EHSiteExceptionType.banned, message: response.data);
      }

      if (data.startsWith('You have exceeded your image')) {
        throw EHSiteException(
            type: EHSiteExceptionType.exceedLimit,
            message: 'exceedImageLimits'.tr);
      }

      if (data.contains('Page load has been aborted due to a fatal error')) {
        throw EHSiteException(
            type: EHSiteExceptionType.ehServerError,
            message: 'ehServerError'.tr,
            shouldPauseAllDownloadTasks: false);
      }
    }
  }
}

class _NHentaiImageInfo {
  final String type;
  final int? width;
  final int? height;

  const _NHentaiImageInfo({
    required this.type,
    required this.width,
    required this.height,
  });
}

class _NHentaiGalleryCache {
  final int gid;
  final String mediaId;
  final GalleryUrl galleryUrl;
  final List<_NHentaiImageInfo> pageInfos;
  final Map<String, dynamic> rawGallery;

  const _NHentaiGalleryCache({
    required this.gid,
    required this.mediaId,
    required this.galleryUrl,
    required this.pageInfos,
    required this.rawGallery,
  });
}
