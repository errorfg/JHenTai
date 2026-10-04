import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Connection settings read from test/e2e/komga_e2e.json (git-ignored; see
/// komga_e2e.example.json). Null when the file is absent, so e2e tests skip.
class KomgaE2eConfig {
  KomgaE2eConfig._(this.java, this.jar);

  final String java;
  final String jar;

  static KomgaE2eConfig? load() {
    final File file = File('test/e2e/komga_e2e.json');
    if (!file.existsSync()) {
      return null;
    }
    final Map<String, dynamic> json =
        (jsonDecode(file.readAsStringSync()) as Map).cast<String, dynamic>();
    final Map<String, dynamic>? local = (json['localKomga'] as Map?)
        ?.cast<String, dynamic>();
    if (local == null ||
        !File(local['jar'] as String).existsSync() ||
        !File(local['java'] as String).existsSync()) {
      return null;
    }
    return KomgaE2eConfig._(local['java'] as String, local['jar'] as String);
  }
}

/// A real Komga server process with a generated library, started for a test
/// run and deleted afterwards.
class LocalKomga {
  LocalKomga._(this._process, this._root, this.port);

  static const String email = 'e2e@example.com';
  static const String password = 'e2e-password';

  final Process _process;
  final Directory _root;
  final int port;
  late final String apiKey;
  late final String libraryId;

  String get serverUrl => 'http://127.0.0.1:$port';

  Directory get libraryDir => Directory('${_root.path}/library');

  final HttpClient _http = HttpClient();

  static Future<LocalKomga> start(KomgaE2eConfig config) async {
    final Directory root = await Directory.systemTemp.createTemp('komga-e2e-');
    final ServerSocket probe = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final int port = probe.port;
    await probe.close();

    final Process process = await Process.start(config.java, <String>[
      '-jar',
      config.jar,
      '--komga.config-dir=${root.path}/config',
      '--server.port=$port',
      '--server.address=127.0.0.1',
    ]);
    final IOSink log = File('${root.path}/komga.log').openWrite();
    process.stdout.listen(log.add);
    process.stderr.listen(log.add);

    final LocalKomga komga = LocalKomga._(process, root, port);
    await komga._waitUntilUp();
    await komga._request(
      'POST',
      '/api/v1/claim',
      headers: <String, String>{
        'X-Komga-Email': email,
        'X-Komga-Password': password,
      },
      basicAuth: false,
    );
    final Map<String, dynamic> key =
        await komga._request(
              'POST',
              '/api/v2/users/me/api-keys',
              body: <String, dynamic>{'comment': 'e2e'},
            )
            as Map<String, dynamic>;
    komga.apiKey = key['key'] as String;

    await TestLibrary.write(komga.libraryDir);
    final Map<String, dynamic> library =
        await komga._request(
              'POST',
              '/api/v1/libraries',
              body: <String, dynamic>{
                'name': 'E2E',
                'root': komga.libraryDir.path,
              },
            )
            as Map<String, dynamic>;
    komga.libraryId = library['id'] as String;
    await komga.waitForAnalysis(TestLibrary.bookCount);
    await komga._waitForSearchIndex();
    return komga;
  }

  Future<void> stop() async {
    _http.close(force: true);
    _process.kill();
    await _process.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    await _root.delete(recursive: true);
  }

  /// Rescan the library and wait until [expectedBooks] non-deleted books are
  /// analysed.
  Future<void> rescan(int expectedBooks) async {
    await _request('POST', '/api/v1/libraries/$libraryId/scan');
    await waitForAnalysis(expectedBooks);
  }

  Future<void> waitForAnalysis(int expectedBooks) async {
    final DateTime deadline = DateTime.now().add(const Duration(minutes: 2));
    while (DateTime.now().isBefore(deadline)) {
      final Map<String, dynamic> page =
          await _request(
                'POST',
                '/api/v1/books/list?size=2000',
                body: <String, dynamic>{
                  'condition': <String, dynamic>{
                    'deleted': <String, dynamic>{'operator': 'isFalse'},
                  },
                },
              )
              as Map<String, dynamic>;
      final List<dynamic> books = page['content'] as List<dynamic>;
      final bool analysed = books.every(
        (dynamic b) => (b['media'] as Map)['status'] != 'UNKNOWN',
      );
      if (books.length == expectedBooks && analysed) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    throw StateError('Komga did not finish analysing the library');
  }

  /// Komga indexes series for full-text search shortly after analysis.
  Future<void> _waitForSearchIndex() async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      final Map<String, dynamic> page =
          await _request(
                'POST',
                '/api/v1/series/list',
                body: <String, dynamic>{'fullTextSearch': TestLibrary.gamma},
              )
              as Map<String, dynamic>;
      if ((page['content'] as List<dynamic>).isNotEmpty) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw StateError('Komga search index did not catch up');
  }

  /// Direct API access with the admin account, standing in for "another
  /// client" (for example the Komga web reader).
  Future<dynamic> api(String method, String path, {Object? body}) =>
      _request(method, path, body: body);

  Future<void> _waitUntilUp() async {
    final DateTime deadline = DateTime.now().add(const Duration(minutes: 1));
    while (DateTime.now().isBefore(deadline)) {
      try {
        await _request('GET', '/api/v1/claim', basicAuth: false);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    throw StateError('Komga did not start; see ${_root.path}/komga.log');
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Object? body,
    Map<String, String> headers = const <String, String>{},
    bool basicAuth = true,
  }) async {
    final HttpClientRequest request = await _http.openUrl(
      method,
      Uri.parse('$serverUrl$path'),
    );
    if (basicAuth) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('$email:$password'))}',
      );
    }
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final HttpClientResponse response = await request.close();
    final String text = await utf8.decoder.bind(response).join();
    if (response.statusCode >= 400) {
      throw HttpException('$method $path -> ${response.statusCode}: $text');
    }
    return text.isEmpty ? null : jsonDecode(text);
  }
}

/// The generated library. Every book has distinct page images so page order
/// can be verified byte for byte.
abstract final class TestLibrary {
  /// Alpha: 5 volumes, 4 pages each, right-to-left manga metadata.
  static const String alpha = 'Alpha Saga';

  /// Beta: 3 volumes, 3 pages each.
  static const String beta = 'Beta Diary';

  /// Gamma: an image EPUB, a text EPUB and a CBZ with a TIFF page.
  static const String gamma = 'Gamma Formats';

  static const int bookCount = 5 + 3 + 3;

  static Future<void> write(Directory root) async {
    for (int volume = 1; volume <= 5; volume++) {
      await _cbz(
        File('${root.path}/$alpha/$alpha v$volume.cbz'),
        series: alpha,
        number: volume,
        pages: 4,
        writer: 'Author A',
        publisher: 'Pub X',
        language: 'ja',
        genre: 'Action',
        tags: 'tag-a',
        manga: 'YesAndRightToLeft',
      );
    }
    for (int volume = 1; volume <= 3; volume++) {
      await _cbz(
        File('${root.path}/$beta/$beta v$volume.cbz'),
        series: beta,
        number: volume,
        pages: 3,
        writer: 'Author B',
        publisher: 'Pub Y',
        language: 'zh',
        genre: 'Slice of Life',
        tags: 'tag-b',
      );
    }
    await _imageEpub(File('${root.path}/$gamma/$gamma 1 images.epub'));
    await _textEpub(File('${root.path}/$gamma/$gamma 2 text.epub'));
    await _cbz(
      File('${root.path}/$gamma/$gamma 3 tiff.cbz'),
      series: gamma,
      number: 3,
      pages: 2,
      tiffPage: true,
    );
  }

  /// Add one more Beta volume, as when a new book arrives in a series.
  static Future<void> addBetaVolume(Directory root, int number) {
    return _cbz(
      File('${root.path}/$beta/$beta v$number.cbz'),
      series: beta,
      number: number,
      pages: 3,
      writer: 'Author B',
      publisher: 'Pub Y',
      language: 'zh',
      genre: 'Slice of Life',
      tags: 'tag-b',
    );
  }

  /// A distinct PNG per (book, page): a 2x2 image whose colour encodes both.
  static Uint8List pagePng(String bookKey, int page) {
    final int seed = bookKey.codeUnits.fold(page * 31, (int a, int b) => a + b);
    return _png(seed % 256, (seed * 7) % 256, (seed * 13) % 256);
  }

  static Future<void> _cbz(
    File file, {
    required String series,
    required int number,
    required int pages,
    String? writer,
    String? publisher,
    String? language,
    String? genre,
    String? tags,
    String? manga,
    bool tiffPage = false,
  }) async {
    final Archive archive = Archive();
    final String key = file.uri.pathSegments.last;
    for (int page = 1; page <= pages; page++) {
      if (tiffPage && page == pages) {
        final Uint8List tiff = _tiff();
        archive.addFile(ArchiveFile('page$page.tif', tiff.length, tiff));
      } else {
        final Uint8List png = pagePng(key, page);
        archive.addFile(
          ArchiveFile(
            'page${page.toString().padLeft(2, '0')}.png',
            png.length,
            png,
          ),
        );
      }
    }
    final String comicInfo =
        '<?xml version="1.0"?><ComicInfo>'
        '<Series>$series</Series><Number>$number</Number>'
        '<Title>$series vol $number</Title>'
        '${writer == null ? '' : '<Writer>$writer</Writer>'}'
        '${publisher == null ? '' : '<Publisher>$publisher</Publisher>'}'
        '${language == null ? '' : '<LanguageISO>$language</LanguageISO>'}'
        '${genre == null ? '' : '<Genre>$genre</Genre>'}'
        '${tags == null ? '' : '<Tags>$tags</Tags>'}'
        '${manga == null ? '' : '<Manga>$manga</Manga>'}'
        '</ComicInfo>';
    final List<int> xml = utf8.encode(comicInfo);
    archive.addFile(ArchiveFile('ComicInfo.xml', xml.length, xml));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(ZipEncoder().encode(archive)!);
  }

  /// Fixed-layout EPUB whose pages are single images (Divina compatible).
  static Future<void> _imageEpub(File file) async {
    const int pages = 3;
    final Archive archive = Archive()
      ..addFile(ArchiveFile.noCompress('mimetype', 20, utf8.encode('application/epub+zip')))
      ..addFile(_text('META-INF/container.xml', _container));
    final StringBuffer manifest = StringBuffer();
    final StringBuffer spine = StringBuffer();
    for (int page = 1; page <= pages; page++) {
      final Uint8List png = pagePng('epub-images', page);
      archive.addFile(ArchiveFile('OEBPS/images/p$page.png', png.length, png));
      archive.addFile(
        _text(
          'OEBPS/p$page.xhtml',
          '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml">'
              '<head><title>p$page</title></head><body><img src="images/p$page.png"/></body></html>',
        ),
      );
      manifest
        ..write('<item id="p$page" href="p$page.xhtml" media-type="application/xhtml+xml"/>')
        ..write('<item id="img$page" href="images/p$page.png" media-type="image/png"/>');
      spine.write('<itemref idref="p$page"/>');
    }
    archive.addFile(
      _text(
        'OEBPS/content.opf',
        _opf(
          title: '$gamma vol 1',
          extraMeta: '<meta property="rendition:layout">pre-paginated</meta>',
          manifest: manifest.toString(),
          spine: spine.toString(),
        ),
      ),
    );
    await file.parent.create(recursive: true);
    await file.writeAsBytes(ZipEncoder().encode(archive)!);
  }

  /// Reflowable text EPUB (not Divina compatible).
  static Future<void> _textEpub(File file) async {
    final String paragraph = List<String>.filled(40, 'Plain novel text.').join(' ');
    final Archive archive = Archive()
      ..addFile(ArchiveFile.noCompress('mimetype', 20, utf8.encode('application/epub+zip')))
      ..addFile(_text('META-INF/container.xml', _container))
      ..addFile(
        _text(
          'OEBPS/c1.xhtml',
          '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml">'
              '<head><title>c1</title></head><body><p>$paragraph</p></body></html>',
        ),
      )
      ..addFile(
        _text(
          'OEBPS/content.opf',
          _opf(
            title: '$gamma vol 2',
            extraMeta: '',
            manifest: '<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>',
            spine: '<itemref idref="c1"/>',
          ),
        ),
      );
    await file.parent.create(recursive: true);
    await file.writeAsBytes(ZipEncoder().encode(archive)!);
  }

  static const String _container =
      '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
      '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>';

  static String _opf({
    required String title,
    required String extraMeta,
    required String manifest,
    required String spine,
  }) =>
      '<?xml version="1.0" encoding="utf-8"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:identifier id="id">urn:uuid:${title.hashCode}</dc:identifier><dc:title>$title</dc:title>'
      '<dc:language>en</dc:language>$extraMeta</metadata>'
      '<manifest>$manifest</manifest><spine>$spine</spine></package>';

  static ArchiveFile _text(String name, String content) {
    final List<int> bytes = utf8.encode(content);
    return ArchiveFile(name, bytes.length, bytes);
  }

  static Uint8List _png(int r, int g, int b) {
    final BytesBuilder raw = BytesBuilder();
    for (int y = 0; y < 2; y++) {
      raw.addByte(0);
      for (int x = 0; x < 2; x++) {
        raw.add(<int>[r, g, b]);
      }
    }
    final List<int> idat = const ZLibEncoder().encode(raw.toBytes());
    final BytesBuilder png = BytesBuilder()
      ..add(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
      ..add(_chunk('IHDR', <int>[0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0]))
      ..add(_chunk('IDAT', idat))
      ..add(_chunk('IEND', <int>[]));
    return png.toBytes();
  }

  static List<int> _chunk(String type, List<int> data) {
    final List<int> typeBytes = ascii.encode(type);
    final ByteData length = ByteData(4)..setUint32(0, data.length);
    final ByteData crc = ByteData(4)
      ..setUint32(0, getCrc32(<int>[...typeBytes, ...data]));
    return <int>[
      ...length.buffer.asUint8List(),
      ...typeBytes,
      ...data,
      ...crc.buffer.asUint8List(),
    ];
  }

  /// Minimal uncompressed 2x2 RGB baseline TIFF (little endian).
  static Uint8List _tiff() {
    const int width = 2, height = 2;
    final List<int> pixels = List<int>.filled(width * height * 3, 200);
    const int entries = 10;
    const int ifdOffset = 8;
    const int ifdSize = 2 + entries * 12 + 4;
    const int bitsOffset = ifdOffset + ifdSize;
    const int pixelOffset = bitsOffset + 6;
    final ByteData d = ByteData(pixelOffset + pixels.length);
    d.setUint8(0, 0x49);
    d.setUint8(1, 0x49);
    d.setUint16(2, 42, Endian.little);
    d.setUint32(4, ifdOffset, Endian.little);
    int p = ifdOffset;
    d.setUint16(p, entries, Endian.little);
    p += 2;
    void entry(int tag, int type, int count, int value) {
      d.setUint16(p, tag, Endian.little);
      d.setUint16(p + 2, type, Endian.little);
      d.setUint32(p + 4, count, Endian.little);
      if (type == 3 && count == 1) {
        d.setUint16(p + 8, value, Endian.little);
      } else {
        d.setUint32(p + 8, value, Endian.little);
      }
      p += 12;
    }

    entry(256, 3, 1, width); // ImageWidth
    entry(257, 3, 1, height); // ImageLength
    entry(258, 3, 3, bitsOffset); // BitsPerSample -> 8,8,8
    entry(259, 3, 1, 1); // Compression: none
    entry(262, 3, 1, 2); // Photometric: RGB
    entry(273, 4, 1, pixelOffset); // StripOffsets
    entry(277, 3, 1, 3); // SamplesPerPixel
    entry(278, 3, 1, height); // RowsPerStrip
    entry(279, 4, 1, pixels.length); // StripByteCounts
    entry(284, 3, 1, 1); // PlanarConfiguration: chunky
    d.setUint32(p, 0, Endian.little);
    for (int i = 0; i < 3; i++) {
      d.setUint16(bitsOffset + i * 2, 8, Endian.little);
    }
    final Uint8List bytes = d.buffer.asUint8List();
    bytes.setRange(pixelOffset, pixelOffset + pixels.length, pixels);
    return bytes;
  }
}
