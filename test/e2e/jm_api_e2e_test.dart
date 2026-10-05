// Live requests to a third-party server whose response times vary widely.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/network/jm/jm_api.dart';
import 'package:jhentai/src/network/jm/jm_image.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';

/// Read-only requests against the live JM API. Enabled by
/// test/e2e/jm_e2e.json (see jm_e2e.example.json).
void main() {
  final File config = File('test/e2e/jm_e2e.json');
  final Map<dynamic, dynamic> settings = config.existsSync()
      ? jsonDecode(config.readAsStringSync()) as Map
      : const <String, dynamic>{};
  if (settings['enabled'] != true) {
    test('JM API e2e', () {}, skip: 'test/e2e/jm_e2e.json is absent');
    return;
  }
  // Optional: an account for the login test.
  final String username = '${settings['username'] ?? ''}';
  final String password = '${settings['password'] ?? ''}';

  final Dio dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );
  List<String> domains = <String>[];
  final JmApi api = JmApi(
    dio: dio,
    apiDomains: () => domains,
    onApiDomainsDiscovered: (List<String> latest) => domains = latest,
  );

  late JmAlbumSummary first;

  test('domain servers list the current API domains', () async {
    final List<String>? latest = await api.fetchLatestApiDomains();
    expect(latest, isNotNull);
    expect(latest, isNotEmpty);
    expect(latest!.every((String d) => d.contains('.')), isTrue);
  });

  test('search decrypts a page of albums', () async {
    final JmSearchResult result = await api.search('MANA');
    expect(result.total, greaterThan(0));
    expect(result.albums, isNotEmpty);
    expect(result.albums.length, lessThanOrEqualTo(JmApi.searchPageSize));
    first = result.albums.first;
    expect(first.id, greaterThan(0));
    expect(first.name, isNotEmpty);
    expect(first.categoryTitle, isNotEmpty);
    // The discovered domains replaced the built-in list.
    expect(domains, isNotEmpty);
  });

  test('an album number search answers with that album', () async {
    final JmSearchResult result = await api.search('${first.id}');
    expect(result.redirectAlbumId, first.id);
  });

  test('the latest list pages through new albums', () async {
    final JmSearchResult result = await api.latest();
    expect(result.albums, isNotEmpty);
  });

  test('a single-chapter album is its own chapter', () async {
    final JmAlbum album = await api.album(first.id);
    expect(album.name, isNotEmpty);
    expect(album.chapters, hasLength(1));
    expect(album.chapters.single.id, album.id);
    final JmChapter chapter = await api.chapter(album.id);
    expect(chapter.albumId, album.id);
    expect(chapter.images, hasLength(album.totalPhotos));
    expect(chapter.images.first, matches(RegExp(r'^\d+\.\w+$')));
  });

  test('a multi-chapter album lists chapters whose pages add up', () async {
    final JmSearchResult result = await api.search('原神', order: 'mv');
    JmAlbum? album;
    for (final JmAlbumSummary summary in result.albums.take(40)) {
      final JmAlbum candidate = await api.album(summary.id);
      if (candidate.chapters.length > 1) {
        album = candidate;
        break;
      }
    }
    expect(album, isNotNull, reason: 'no multi-chapter album found');
    expect(album!.chapters.first.id, album.id);
    int pages = 0;
    for (final JmChapterRef ref in album.chapters) {
      final JmChapter chapter = await api.chapter(ref.id);
      expect(chapter.albumId, album.id);
      pages += chapter.images.length;
    }
    expect(pages, album.totalPhotos);
  });

  test('comments of an album are readable', () async {
    final List<JmComment> comments = await api.comments(first.id);
    for (final JmComment comment in comments) {
      expect(comment.id, greaterThan(0));
      expect(comment.content, isNotEmpty);
    }
  });

  test('the lines are measured on this network', () async {
    final JmLineMeasurement measurement = await api.measureLines(
      domains,
      <String>[...JmApi.imageDomains],
    );
    expect(measurement.api.keys, domains);
    expect(measurement.api.values.whereType<Duration>(), isNotEmpty);
    expect(measurement.image.values.whereType<Duration>(), isNotEmpty);
    expect(measurement.recommendedImageHost, isNotEmpty);
  });

  test('a first start waits for the first measurement', () async {
    JmLineMeasurement? saved;
    final JmApi measuring = JmApi(
      dio: dio,
      apiDomains: () => domains,
      discoverDomains: false,
      linesMeasuredAt: () => saved == null ? null : DateTime.now(),
      imageDomainCandidates: () => JmApi.imageDomains.take(2).toList(),
      onLinesMeasured: (JmLineMeasurement m) async => saved = m,
    );
    await measuring.latest();
    expect(saved, isNotNull);
    expect(saved!.image.keys, JmApi.imageDomains.take(2));
  });

  test('a refused login reports the server message', () async {
    await expectLater(
      api.login('jhentai-e2e-no-such-user-7f3a', 'not-a-password'),
      throwsA(
        isA<JmApiException>().having(
          (JmApiException e) => e.message,
          'message',
          isNotEmpty,
        ),
      ),
    );
  });

  test(
    'an account logs in and its session is sent afterwards',
    () async {
      final ({JmUser user, String cookie}) account = await api.login(
        username,
        password,
      );
      expect(account.user.id, greaterThan(0));
      expect(account.user.username.toLowerCase(), username.toLowerCase());
      expect(account.cookie, contains('AVS='));

      final JmApi loggedIn = JmApi(
        dio: dio,
        apiDomains: () => domains,
        accountCookie: () => account.cookie,
        discoverDomains: false,
      );
      expect((await loggedIn.album(first.id)).id, first.id);
    },
    skip: username.isEmpty || password.isEmpty
        ? 'no account in test/e2e/jm_e2e.json'
        : false,
  );

  test('restoring a scrambled page removes the strip seams', () async {
    final JmChapter chapter = await api.chapter(first.id);
    final int scrambleId = await api.scrambleId(chapter.id);
    expect(scrambleId, greaterThan(0));
    final String fileName = chapter.images.first;
    final int strips = JmImage.stripCount(
      scrambleId: scrambleId,
      chapterId: chapter.id,
      fileName: fileName,
    );
    expect(strips, greaterThan(0), reason: 'new albums are scrambled');

    final String url = JmImage.pageUrl(
      imageDomain: JmApi.imageDomains.first,
      chapterId: chapter.id,
      fileName: fileName,
      strips: strips,
    );
    expect(JmImage.stripsOf(url), strips);
    final Response<List<int>> response = await dio.get<List<int>>(
      JmImage.requestUrl(url),
      options: Options(
        responseType: ResponseType.bytes,
        headers: JmApi.imageHeaders(api.currentApiDomain),
      ),
    );
    final Uint8List bytes = Uint8List.fromList(response.data!);
    final img.Image scrambled = img.decodeImage(bytes)!;

    final List<({int srcY, int dstY, int height})> layout =
        JmImage.stripLayout(scrambled.height, strips);
    // Edges between strips in the stored image, and in the restored one.
    final List<int> storedEdges = <int>[
      for (final ({int srcY, int dstY, int height}) s in layout)
        if (s.srcY > 0) s.srcY,
    ];
    final List<int> restoredEdges = <int>[
      for (final ({int srcY, int dstY, int height}) s in layout)
        if (s.dstY > 0) s.dstY,
    ];

    final img.Image restored = img.decodeJpg(
      JmImage.restoreToJpeg(bytes, strips),
    )!;
    expect(restored.width, scrambled.width);
    expect(restored.height, scrambled.height);

    final double stored = _meanRowJump(scrambled, storedEdges);
    final double after = _meanRowJump(restored, restoredEdges);
    final double typical = _medianRowJump(restored);
    // The stored image breaks at its strip edges; the restored one runs on.
    expect(stored, greaterThan(after * 3));
    expect(after, lessThan(typical * 10 + 8));
  });
}

/// Mean absolute difference between row y-1 and row y.
double _rowJump(img.Image image, int y) {
  int sum = 0;
  for (int x = 0; x < image.width; x++) {
    final img.Pixel a = image.getPixel(x, y - 1);
    final img.Pixel b = image.getPixel(x, y);
    sum += (a.r - b.r).abs().toInt() +
        (a.g - b.g).abs().toInt() +
        (a.b - b.b).abs().toInt();
  }
  return sum / (image.width * 3);
}

double _meanRowJump(img.Image image, List<int> rows) =>
    rows.map((int y) => _rowJump(image, y)).reduce((a, b) => a + b) /
    rows.length;

double _medianRowJump(img.Image image) {
  final List<double> jumps = <double>[
    for (int y = 1; y < image.height; y += 7) _rowJump(image, y),
  ]..sort();
  return jumps[jumps.length ~/ 2];
}
