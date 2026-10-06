import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/model/gallery_thumbnail.dart';
import 'package:jhentai/src/widget/eh_thumbnail.dart';

/// A page-sized image covered with a halftone screen: round dots on a grid
/// at 45 degrees, [pitch] pixels apart. A JM page is 1672 pixels wide, so
/// a common 65-line screen on a B5 page is about 4 pixels apart.
Uint8List _halftone({required int width, required int height, required double pitch}) {
  final img.Image tone = img.Image(width: width, height: height);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final double u = (x + y) / math.sqrt2 / pitch;
      final double v = (x - y) / math.sqrt2 / pitch;
      final double du = u - u.roundToDouble();
      final double dv = v - v.roundToDouble();
      final int value = du * du + dv * dv < 0.12 ? 0 : 255;
      tone.setPixelRgb(x, y, value, value, value);
    }
  }
  return img.encodePng(tone);
}

/// Spread of the grey levels in the middle of [rendered], where the
/// thumbnail is: an even grey is near 0, coarse dots are far from it.
Future<double> _deviation(ui.Image rendered) async {
  final ByteData pixels = (await rendered.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final List<int> grey = <int>[
    for (int y = rendered.height ~/ 4; y < rendered.height * 3 ~/ 4; y++)
      for (int x = rendered.width * 3 ~/ 8; x < rendered.width * 5 ~/ 8; x++) pixels.getUint8((y * rendered.width + x) * 4),
  ];
  final double mean = grey.reduce((int a, int b) => a + b) / grey.length;
  return math.sqrt(grey.map((int v) => (v - mean) * (v - mean)).reduce((double a, double b) => a + b) / grey.length);
}

void main() {
  late HttpServer server;
  late Directory cache;
  final Uint8List page = _halftone(width: 1672, height: 2400, pitch: 4);

  setUpAll(() async {
    // flutter_test answers every HTTP request with 400 unless told not to.
    HttpOverrides.global = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) {
      request.response
        ..headers.contentType = ContentType('image', 'png')
        ..add(page)
        ..close();
    });
    cache = Directory.systemTemp.createTempSync('jm_thumbnail_display_test');
  });

  tearDownAll(() async {
    await server.close(force: true);
    cache.deleteSync(recursive: true);
  });

  /// A details page thumbnail cell, 150 x 180 logical pixels on a screen of
  /// pixel density 3, as drawn on screen once its image has loaded.
  Future<({ui.Image rendered, ui.Image held})> showThumbnail(WidgetTester tester, String url) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    // The network image provider keeps downloads in the temporary directory.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => cache.path,
    );

    final GlobalKey cell = GlobalKey();
    await tester.runAsync(
      () => tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: cell,
              child: SizedBox(
                width: 150,
                height: 180,
                child: LayoutBuilder(
                  builder: (_, BoxConstraints constraints) => EHThumbnail(
                    thumbnail: GalleryThumbnail(href: 'jm://1/1', isLarge: true, thumbUrl: url),
                    containerWidth: constraints.maxWidth,
                    containerHeight: constraints.maxHeight,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // Loading happens on real time: the download and the decoding.
    for (int i = 0; i < 200 && find.byType(ExtendedRawImage).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.byType(ExtendedRawImage), findsOneWidget, reason: 'the thumbnail did not load');
    await tester.pumpAndSettle();

    final ui.Image held = tester.widget<ExtendedRawImage>(find.byType(ExtendedRawImage)).image!;
    final RenderRepaintBoundary boundary = cell.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image rendered = (await tester.runAsync(() => boundary.toImage(pixelRatio: 3)))!;
    return (rendered: rendered, held: held);
  }

  for (final ({String name, String fragment}) kind in <({String name, String fragment})>[
    (name: 'stored in strips', fragment: '#jmStrips=10'),
    (name: 'stored whole', fragment: ''),
  ]) {
    testWidgets('a JM page ${kind.name} shows as a details thumbnail without coarse dots', (WidgetTester tester) async {
      final String url = 'http://${server.address.host}:${server.port}/media/photos/300000/00001.webp${kind.fragment}';
      final ({ui.Image rendered, ui.Image held}) shown = await showThumbnail(tester, url);

      await tester.runAsync(() async {
        // Drawn from the full page the spread was 93. A Lanczos resize of
        // this image to the same size leaves 11.0 of fine texture: the
        // screen is close to the finest detail a thumbnail can hold.
        expect(await _deviation(shown.rendered), lessThan(11));
      });

      // Shrunk once to the cell's pixels, not kept at 1672 x 2400 for the
      // screen to shrink on every frame.
      expect(shown.held.width, lessThanOrEqualTo(450));
      expect(shown.held.height, lessThanOrEqualTo(540));
      expect(shown.held.height, greaterThanOrEqualTo(530), reason: 'as sharp as the cell allows');
    });
  }
}
