import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/service/komga_download_service.dart';
import 'package:jhentai/src/service/log.dart';

class _SilentLogService extends LogService {
  @override
  void trace(Object msg, [bool withStack = false]) {}
  @override
  void debug(Object msg, [bool withStack = false]) {}
  @override
  void info(Object msg, [bool withStack = false]) {}
  @override
  void warning(Object msg, [Object? error, bool withStack = false]) {}
  @override
  void error(Object msg, [Object? error, StackTrace? stackTrace]) {}
}

Uint8List _page(int n) => img.encodePng(img.Image(width: 8, height: 8)..clear(img.ColorRgb8(n * 40, 0, 0)));

/// A Komga server with two books: a CBR (`rar`) and a CBZ (`zip`), three
/// pages each. Paths asked for are written down.
class _Komga {
  late HttpServer server;
  final List<String> asked = <String>[];

  Map<String, dynamic> book(String id) => <String, dynamic>{
        'id': id,
        'seriesId': 's',
        'name': 'Book $id',
        'metadata': <String, dynamic>{'title': 'Book $id', 'number': '1', 'numberSort': 1},
        'media': <String, dynamic>{
          'status': 'READY',
          'pagesCount': 3,
          'mediaType': id == 'rar' ? 'application/x-rar-compressed; version=4' : 'application/zip',
          'mediaProfile': 'DIVINA',
        },
      };

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      asked.add(request.uri.path);
      final List<String> parts = request.uri.pathSegments;
      final String id = parts.length > 3 ? parts[3] : '';
      if (parts.length == 4) {
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(book(id)));
      } else if (parts.length == 5 && parts[4] == 'pages') {
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(<Map<String, dynamic>>[
            for (int n = 1; n <= 3; n++) <String, dynamic>{'number': n, 'fileName': 'p$n.png', 'mediaType': 'image/png', 'width': 8, 'height': 8},
          ]));
      } else if (parts.length == 6 && parts[4] == 'pages') {
        request.response
          ..headers.contentType = ContentType('image', 'png')
          ..add(_page(int.parse(parts[5])));
      } else if (parts.length == 5 && parts[4] == 'file' && id == 'zip') {
        final Archive archive = Archive();
        for (int n = 1; n <= 3; n++) {
          final Uint8List page = _page(n);
          archive.addFile(ArchiveFile('p$n.png', page.length, page));
        }
        request.response.add(ZipEncoder().encode(archive)!);
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
  }
}

/// Offline Komga downloads, whatever the book's format.
void main() {
  late _Komga komga;
  late Directory root;
  late KomgaClient client;
  late KomgaDownloadService downloads;

  setUp(() async {
    log = _SilentLogService();
    HttpOverrides.global = null;
    komga = _Komga();
    await komga.start();
    root = Directory.systemTemp.createTempSync('komga_download_test');
    client = KomgaClient(serverUrl: 'http://127.0.0.1:${komga.server.port}', username: 'reader', password: 'secret', apiKey: '');
    downloads = KomgaDownloadService(rootProvider: () => root);
  });

  tearDown(() async {
    await komga.server.close(force: true);
    root.deleteSync(recursive: true);
  });

  Future<KomgaDownloadedBook?> download(String id) async {
    downloads.enqueue(client, KomgaBook.fromJson(komga.book(id)));
    await Future<void>.delayed(Duration.zero);
    await downloads.whenIdle();
    return downloads.downloaded(client.progressRecordKey(id));
  }

  test('a CBR book is downloaded page by page, as the server serves its pages', () async {
    final KomgaDownloadedBook? book = await download('rar');
    expect(book, isNotNull, reason: '${downloads.task(client.progressRecordKey('rar'))?.error}');
    expect(komga.asked.where((String path) => path.endsWith('/file')), isEmpty);
    expect(komga.asked.where((String path) => RegExp(r'/pages/\d+$').hasMatch(path)), hasLength(3));
    expect(book!.imagePaths.map((String path) => path.split(Platform.pathSeparator).last), <String>['0001.png', '0002.png', '0003.png']);
    for (int n = 1; n <= 3; n++) {
      final img.Image page = img.decodePng(File(book.imagePaths[n - 1]).readAsBytesSync())!;
      expect(page.getPixel(4, 4).r, n * 40, reason: 'page $n in its place');
    }

    // Read again from its manifest.
    await downloads.reload();
    expect(downloads.downloaded(client.progressRecordKey('rar'))?.imagePaths, hasLength(3));
  });

  test('a CBZ book is still fetched whole and unpacked', () async {
    final KomgaDownloadedBook? book = await download('zip');
    expect(book, isNotNull, reason: '${downloads.task(client.progressRecordKey('zip'))?.error}');
    expect(komga.asked.where((String path) => path.endsWith('/file')), hasLength(1));
    expect(komga.asked.where((String path) => RegExp(r'/pages/\d+$').hasMatch(path)), isEmpty);
    expect(book!.imagePaths, hasLength(3));
    expect(File('${root.path}/${client.connectionId}/zip/book.part').existsSync(), isFalse);
  });
}
