import 'package:jhentai/src/model/content_scheme.dart';

/// The sites galleries come from. [key] is written down, so it stays as it
/// is: unlike the order of the values or their names on screen.
enum SourceKind {
  ehentai('eh', ContentScheme.ehentai),
  nhentai('nh', ContentScheme.nhentai),
  wnacg('wn', ContentScheme.wnacg),
  jm('jm', ContentScheme.jm),
  tachiyomi('tachi', ContentScheme.tachiyomi);

  const SourceKind(this.key, this.scheme);

  final String key;

  /// Where the app shows the site.
  final ContentScheme scheme;
}

/// Where a gallery comes from: a site, and for a site that has several
/// sources, which one (a Tachiyomi source). Mirrors of a site (ExHentai,
/// nhentai.to) are the same source.
class ContentSource {
  const ContentSource(this.kind, [this.instance]);

  static const ContentSource ehentai = ContentSource(SourceKind.ehentai);
  static const ContentSource nhentai = ContentSource(SourceKind.nhentai);
  static const ContentSource wnacg = ContentSource(SourceKind.wnacg);
  static const ContentSource jm = ContentSource(SourceKind.jm);

  final SourceKind kind;

  /// The id of a Tachiyomi source; null for a site that is one source.
  final String? instance;

  String get key => instance == null ? kind.key : '${kind.key}:$instance';

  /// A series of chapters, each read and kept on its own.
  bool get hasChapters => kind == SourceKind.jm || kind == SourceKind.tachiyomi;

  /// Kept in the app's own favorites: the site has no favorites of its
  /// account that the app uses.
  bool get favoritesOnDevice => kind == SourceKind.wnacg || hasChapters;

  @override
  bool operator ==(Object other) => other is ContentSource && other.kind == kind && other.instance == instance;

  @override
  int get hashCode => Object.hash(kind, instance);

  @override
  String toString() => key;
}

/// What a source offers on a gallery's page besides reading it: E-Hentai
/// has all of it, the others some. [nhentaiApi]: nhentai is reached through
/// its official API with a key, which has archives, torrents, comments,
/// related galleries and the account's tag blacklist.
class SourceFeatures {
  const SourceFeatures(this.source, {this.nhentaiApi = false});

  final ContentSource source;
  final bool nhentaiApi;

  bool get _eh => source.kind == SourceKind.ehentai;

  bool get _nhApi => source.kind == SourceKind.nhentai && nhentaiApi;

  bool get rating => _eh;

  bool get archives => _eh || _nhApi;

  bool get torrents => _eh || _nhApi;

  /// Downloads through Hentai@Home.
  bool get hathDownload => _eh;

  bool get statistics => _eh;

  /// Shown in the watched list.
  bool get watched => _eh;

  /// Tags voted on and added.
  bool get tagVotes => _eh;

  /// Tags put on the account's blacklist.
  bool get tagBlacklist => _nhApi;

  /// A version replaced by an update of the uploader, whose progress the
  /// new one takes over.
  bool get olderVersions => _eh;

  /// Reached at E-Hentai or ExHentai, either one.
  bool get twoDomains => _eh;

  bool get comments => source.kind != SourceKind.wnacg && (source.kind != SourceKind.nhentai || nhentaiApi);

  /// Comments voted on, written and edited.
  bool get commentActions => _eh;

  /// How many comments there are in all, besides those shown.
  bool get commentCount => comments && (source.kind == SourceKind.nhentai || source.kind == SourceKind.jm);

  /// Galleries the site lists as related, shown instead of a search.
  bool get relatedGalleries => source.kind == SourceKind.jm || _nhApi;

  /// The title looked up on E-Hentai.
  bool get searchOnEHentai => !_eh;
}
