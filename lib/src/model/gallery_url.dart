import 'package:jhentai/src/exception/internal_exception.dart';
import 'package:jhentai/src/setting/eh_setting.dart';

class GalleryUrl {
  final bool isEH;
  final bool isNH;
  final bool isWN;
  final bool isJM;
  final String? sourceHost;

  final int gid;

  final String token;

  const GalleryUrl({
    required this.isEH,
    required this.gid,
    required this.token,
    this.isNH = false,
    this.isWN = false,
    this.isJM = false,
    this.sourceHost,
  }) : assert(isWN || isNH || isJM || token.length == 10);

  /// JM ids share their range with E-Hentai gids; tables keyed by gid
  /// (downloads, history) would mix them up, so JM gids are shifted.
  static const int jmGidOffset = 9000000000;

  /// A JM chapter; an album's first chapter has the album's id.
  factory GalleryUrl.jm(int chapterId) => GalleryUrl(
        isEH: true,
        isJM: true,
        gid: jmGidOffset + chapterId,
        token: 'jmcomic',
      );

  int get jmChapterId => gid - jmGidOffset;

  static GalleryUrl? tryParse(String url) {
    RegExp regExp =
        RegExp(r'https://e([-x])hentai\.org/g/(\d+)/([a-z0-9]{10})');
    Match? match = regExp.firstMatch(url);
    if (match != null) {
      return GalleryUrl(
        isEH: match.group(1) == '-',
        gid: int.parse(match.group(2)!),
        token: match.group(3)!,
      );
    }

    for (String domain in ehSetting.nhentaiDomains) {
      String escapedDomain = domain.replaceAll('.', r'\.');
      RegExp nhRegExp = RegExp('https?://(?:www\\.)?$escapedDomain/g/(\\d+)(?:/|\$)');
      Match? nhMatch = nhRegExp.firstMatch(url);
      if (nhMatch != null) {
        return GalleryUrl(
          isEH: true,
          isNH: true,
          gid: int.parse(nhMatch.group(1)!),
          token: 'nhentai',
          sourceHost: domain,
        );
      }
    }

    Uri? wnUri = Uri.tryParse(url);
    if (wnUri != null) {
      String host = wnUri.host;
      bool isWnHost = host == 'wnacg.com' || host == 'www.wnacg.com' || host == ehSetting.wnacgDomain.value;
      if (isWnHost) {
        RegExp wnAidRegExp = RegExp(r'aid-(\d+)');
        Match? wnMatch = wnAidRegExp.firstMatch(wnUri.path);
        if (wnMatch != null) {
          return GalleryUrl(
            isEH: true,
            isWN: true,
            gid: int.parse(wnMatch.group(1)!),
            token: 'wnacg',
          );
        }
      }
    }

    if (wnUri != null && _isJmHost(wnUri.host)) {
      Match? jmMatch = RegExp(r'^/(?:album|photo)/(\d+)').firstMatch(wnUri.path);
      if (jmMatch != null) {
        return GalleryUrl.jm(int.parse(jmMatch.group(1)!));
      }
    }

    return null;
  }

  static bool _isJmHost(String host) => host.contains('18comic') || host.contains('jmcomic');

  static GalleryUrl parse(String url) {
    GalleryUrl? galleryUrl = tryParse(url);
    if (galleryUrl == null) {
      throw InternalException(message: 'Parse gallery url failed, url:$url');
    }

    return galleryUrl;
  }

  String get url {
    if (isJM) {
      return 'https://18comic.vip/photo/$jmChapterId';
    }
    if (isWN) {
      return 'https://${ehSetting.wnacgDomain.value}/photos-index-aid-$gid.html';
    }
    if (isNH) {
      return 'https://${sourceHost ?? 'nhentai.net'}/g/$gid/';
    }
    return isEH
        ? 'https://e-hentai.org/g/$gid/$token/'
        : 'https://exhentai.org/g/$gid/$token/';
  }

  GalleryUrl copyWith({
    bool? isEH,
    bool? isNH,
    bool? isWN,
    bool? isJM,
    String? sourceHost,
    int? gid,
    String? token,
  }) {
    return GalleryUrl(
      isEH: isEH ?? this.isEH,
      isNH: isNH ?? this.isNH,
      isWN: isWN ?? this.isWN,
      isJM: isJM ?? this.isJM,
      sourceHost: sourceHost ?? this.sourceHost,
      gid: gid ?? this.gid,
      token: token ?? this.token,
    );
  }

  @override
  String toString() {
    return 'GalleryUrl{isEH: $isEH, isNH: $isNH, isWN: $isWN, isJM: $isJM, sourceHost: $sourceHost, gid: $gid, token: $token}';
  }
}
