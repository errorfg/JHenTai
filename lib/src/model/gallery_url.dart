import 'package:jhentai/src/exception/internal_exception.dart';

class GalleryUrl {
  final bool isEH;
  final bool isNH;

  final int gid;

  final String token;

  const GalleryUrl({
    required this.isEH,
    required this.gid,
    required this.token,
    this.isNH = false,
  }) : assert(isNH || token.length == 10);

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

    RegExp nhRegExp = RegExp(r'https?://(?:www\.)?nhentai\.net/g/(\d+)(?:/|$)');
    Match? nhMatch = nhRegExp.firstMatch(url);
    if (nhMatch != null) {
      return GalleryUrl(
        isEH: true,
        isNH: true,
        gid: int.parse(nhMatch.group(1)!),
        token: 'nhentai',
      );
    }

    return null;
  }

  static GalleryUrl parse(String url) {
    GalleryUrl? galleryUrl = tryParse(url);
    if (galleryUrl == null) {
      throw InternalException(message: 'Parse gallery url failed, url:$url');
    }

    return galleryUrl;
  }

  String get url {
    if (isNH) {
      return 'https://nhentai.net/g/$gid/';
    }
    return isEH
        ? 'https://e-hentai.org/g/$gid/$token/'
        : 'https://exhentai.org/g/$gid/$token/';
  }

  GalleryUrl copyWith({
    bool? isEH,
    bool? isNH,
    int? gid,
    String? token,
  }) {
    return GalleryUrl(
      isEH: isEH ?? this.isEH,
      isNH: isNH ?? this.isNH,
      gid: gid ?? this.gid,
      token: token ?? this.token,
    );
  }

  @override
  String toString() {
    return 'GalleryUrl{isEH: $isEH, isNH: $isNH, gid: $gid, token: $token}';
  }
}
