import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jhentai/src/network/tachi/tachi_client.dart';
import 'package:jhentai/src/network/tachi/tachi_host.dart';
import 'package:jhentai/src/network/tachi/tachi_models.dart';
import 'package:jhentai/src/service/path_service.dart';

import 'testext_apk.dart';

/// The extension host on a device (Android: the system's runtime; iOS: the
/// OpenJDK in the app): the test extension is installed and every call
/// reaches a stand-in for its site on this device.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer site;
  final List<String> asked = <String>[];
  final Uint8List png = Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]);

  setUpAll(() async {
    // Test bindings may answer HTTP themselves; these requests are real.
    HttpOverrides.global = null;
    await pathService.initBean();
    site = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    site.listen((HttpRequest request) async {
      asked.add(request.uri.toString());
      final String base = 'http://127.0.0.1:${site.port}';
      final HttpResponse r = request.response;
      switch (request.uri.path) {
        case '/list':
          r.headers.add('Set-Cookie', 'session=abc; Path=/; Max-Age=3600');
          r.write('{"items":[{"id":"1","title":"First"},{"id":"2","title":"Second"}],"next":"true"}');
        case '/search':
          r.write('{"items":[{"id":"3","title":"Found ${request.uri.queryParameters['q']}"}],"next":"false"}');
        case '/manga/1':
          r.write('{"title":"First","author":"Someone","description":"About","genres":["a","b"]}');
        case '/manga/1/chapters':
          r.write('[{"url":"/chapter/2","name":"Ch. 2","date":"200"},{"url":"/chapter/1","name":"Ch. 1","date":"100"}]');
        case '/chapter/1':
          r.write('["$base/img/0.png","$base/page/1"]');
        case '/page/1':
          r.write('$base/img/1.png');
        case '/h5':
          // For the WebView probe: an HttpOnly cookie, a request with a
          // header, a call into the extension's JavaScript interface.
          r.headers.add('Set-Cookie', 'token=abc; Path=/; HttpOnly');
          r.headers.contentType = ContentType.html;
          r.write("""<!doctype html><html><head><title>Probe</title><script>
var x = new XMLHttpRequest();
x.open('GET', '/api/v3/system/config/2020/1');
x.setRequestHeader('Authorization', 'Token xyz');
x.send();
window.Native.sendToken('from-js');
</script></head><body>ok</body></html>""");
        case '/api/v3/system/config/2020/1':
          r.write('{}');
        case '/img/0.png' || '/img/1.png' || '/cover/1':
          r.headers.contentType = ContentType('image', 'png');
          r.add(png);
        default:
          r.statusCode = 404;
      }
      await r.close();
    });
  });

  tearDownAll(() => site.close(force: true));

  testWidgets('installs an extension and serves every call through it', (WidgetTester tester) async {
    final TachiClient client = await tachiHost.client();
    expect(await client.extensions(), isEmpty);

    final File apk = File('${Directory.systemTemp.path}/testext.apk')..writeAsBytesSync(base64.decode(testExtensionApkBase64));
    final TachiExtension extension = await client.install(apk.path);
    expect(extension.name, 'Test Source');
    final String source = extension.sources.single.id;

    await client.setPreferenceStore(source, <String, dynamic>{
      'base_url': <String, dynamic>{'t': 'string', 'v': 'http://127.0.0.1:${site.port}'},
    });

    final TachiMangasPage popular = await client.popular(source, 1);
    expect(popular.mangas.map((TachiManga m) => m.title), <String>['First', 'Second']);
    expect(popular.hasNextPage, isTrue);

    final List<TachiFilter> filters = await client.filters(source);
    expect(filters.map((TachiFilter f) => f.type), <String>['header', 'select', 'checkbox', 'group', 'sort']);
    filters[1].state = 1;
    final TachiMangasPage found = await client.search(source, 1, 'tea', filters: filters);
    expect(found.mangas.single.title, 'Found tea');
    expect(asked.last, contains('genre=action'));

    final TachiManga details = await client.details(source, popular.mangas.first);
    expect(details.author, 'Someone');
    final List<TachiChapter> chapters = await client.chapters(source, details);
    expect(chapters.map((TachiChapter c) => c.name), <String>['Ch. 2', 'Ch. 1']);
    final List<TachiPage> pages = await client.pages(source, chapters.last);
    expect(pages, hasLength(2));

    expect(await client.bytes(client.imageUri(source, imageUrl: pages[0].imageUrl)), png);
    expect(await client.bytes(client.imageUri(source, pageUrl: pages[1].url, index: 1)), png, reason: 'image URL found by the source');
    expect(await client.bytes(client.coverUri(source, popular.mangas.first.thumbnailUrl!)), png);

    // The site's cookie went back with the next request.
    await client.popular(source, 2);
    final List<TachiPreference> preferences = await client.preferences(source);
    expect(preferences.map((TachiPreference p) => p.type), <String>['list', 'switch']);
    final List<TachiPreference> changed = await client.setPreference(source, 'sort', 'new');
    expect(changed.first.value, 'new');

    // The extension's own WebView: the system's on Android, the app's
    // WKWebView on iOS (tachi_browser.dart).
    final List<String> probe = (await client.search(source, 1, 'webview:http://127.0.0.1:${site.port}/h5')).mangas.map((TachiManga m) => m.title).toList();
    expect(probe, containsAll(<String>['auth:Token xyz', 'eval:"Probe"', 'js:from-js']));
    expect(probe.firstWhere((String t) => t.startsWith('cookie:')), contains('token=abc'));

    await client.uninstall(extension.pkg);
    expect(await client.extensions(), isEmpty);
  });
}
