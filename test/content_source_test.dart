import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/content_scheme.dart';
import 'package:jhentai/src/model/content_source.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/setting/eh_setting.dart';

/// What each source offers on a gallery's page, by [SourceFeatures]' names.
Map<String, bool> _features(SourceFeatures f) => <String, bool>{
      'rating': f.rating,
      'archives': f.archives,
      'torrents': f.torrents,
      'hathDownload': f.hathDownload,
      'statistics': f.statistics,
      'watched': f.watched,
      'tagVotes': f.tagVotes,
      'tagBlacklist': f.tagBlacklist,
      'olderVersions': f.olderVersions,
      'twoDomains': f.twoDomains,
      'comments': f.comments,
      'commentActions': f.commentActions,
      'commentCount': f.commentCount,
      'relatedGalleries': f.relatedGalleries,
      'searchOnEHentai': f.searchOnEHentai,
    };

Set<String> _offered(SourceFeatures f) => _features(f).entries.where((e) => e.value).map((e) => e.key).toSet();

void main() {
  setUp(() {
    ehSetting.nhentaiDomains.value = <String>['nhentai.net', 'nhentai.to'];
  });

  test('each gallery is of its site; the keys stay what they are', () {
    expect(GalleryUrl.parse('https://e-hentai.org/g/3400000/abcdef1234/').source.key, 'eh');
    expect(GalleryUrl.parse('https://exhentai.org/g/3400000/abcdef1234/').source, ContentSource.ehentai);
    expect(GalleryUrl.parse('https://nhentai.net/g/501/').source.key, 'nh');
    expect(GalleryUrl.parse('https://nhentai.to/g/501/').source, ContentSource.nhentai, reason: 'a mirror is the same source');
    expect(GalleryUrl.parse('https://www.wnacg.com/photos-index-aid-77.html').source.key, 'wn');
    expect(GalleryUrl.jm(1234).source.key, 'jm');
    final ContentSource tachi = GalleryUrl.tachiChapter('2499283573021220255', '/manga/1', '/chapter/1').source;
    expect(tachi.key, 'tachi:2499283573021220255');
    expect(tachi, GalleryUrl.tachiManga('2499283573021220255', '/manga/1').source);
    expect(tachi == GalleryUrl.tachiManga('1', '/manga/1').source, isFalse, reason: 'two Tachiyomi sources are two sources');

    expect(<String>{for (final SourceKind kind in SourceKind.values) kind.key}, <String>{'eh', 'nh', 'wn', 'jm', 'tachi'});
    expect(GalleryUrl.jm(1).source.kind.scheme, ContentScheme.jm);
  });

  test('what each site offers on a gallery page', () {
    expect(_offered(const SourceFeatures(ContentSource.ehentai)), <String>{
      'rating',
      'archives',
      'torrents',
      'hathDownload',
      'statistics',
      'watched',
      'tagVotes',
      'olderVersions',
      'twoDomains',
      'comments',
      'commentActions',
    });
    expect(_offered(const SourceFeatures(ContentSource.nhentai)), <String>{'searchOnEHentai'});
    expect(_offered(const SourceFeatures(ContentSource.nhentai, nhentaiApi: true)), <String>{
      'archives',
      'torrents',
      'tagBlacklist',
      'comments',
      'commentCount',
      'relatedGalleries',
      'searchOnEHentai',
    });
    expect(_offered(const SourceFeatures(ContentSource.wnacg)), <String>{'searchOnEHentai'});
    expect(_offered(const SourceFeatures(ContentSource.jm)), <String>{'comments', 'commentCount', 'relatedGalleries', 'searchOnEHentai'});
    expect(_offered(const SourceFeatures(ContentSource(SourceKind.tachiyomi, '1'))), <String>{'comments', 'searchOnEHentai'});
    // The nhentai API changes nothing for the other sites.
    expect(_offered(const SourceFeatures(ContentSource.jm, nhentaiApi: true)), _offered(const SourceFeatures(ContentSource.jm)));
  });

  test('a search of a gallery\'s own site', () {
    SearchConfig on(ContentSource source) => SearchConfig(keyword: 'k')..searchOn(source);
    expect((on(ContentSource.nhentai).isNhSearch, on(ContentSource.nhentai).isJmSearch), (true, false));
    expect(on(ContentSource.wnacg).isWnacgSearch, isTrue);
    expect(on(ContentSource.jm).isJmSearch, isTrue);
    expect(on(const ContentSource(SourceKind.tachiyomi, '42')).tachiSource, '42');
    final SearchConfig eh = SearchConfig(keyword: 'k', isJmSearch: true, tachiSource: '42')..searchOn(ContentSource.ehentai);
    expect((eh.isNhSearch, eh.isWnacgSearch, eh.isJmSearch, eh.tachiSource), (false, false, false, null));
  });

  test('local favorites and chapters', () {
    expect(<SourceKind>[for (final SourceKind kind in SourceKind.values) if (ContentSource(kind).favoritesOnDevice) kind], <SourceKind>[SourceKind.wnacg, SourceKind.jm, SourceKind.tachiyomi]);
    expect(<SourceKind>[for (final SourceKind kind in SourceKind.values) if (ContentSource(kind).hasChapters) kind], <SourceKind>[SourceKind.jm, SourceKind.tachiyomi]);
  });
}
