import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/network/jm/jm_image.dart';
import 'package:jhentai/src/widget/jm_network_image_provider.dart';

/// Ten horizontal bands of distinct colour, 100 rows each.
img.ColorRgb8 _band(int band) => img.ColorRgb8(band * 25, 0, 255 - band * 25);

/// An image JM would store: the bands cut into strips and stacked
/// bottom-up, so that restoring yields the bands in order.
Uint8List _scrambled({required int width, required int height, required int strips}) {
  final img.Image original = img.Image(width: width, height: height);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      original.setPixel(x, y, _band(y * 10 ~/ height));
    }
  }
  final img.Image stored = img.Image(width: width, height: height);
  for (final ({int srcY, int dstY, int height}) strip in JmImage.stripLayout(height, strips)) {
    img.compositeImage(
      stored,
      original,
      dstY: strip.srcY,
      dstW: width,
      dstH: strip.height,
      srcY: strip.dstY,
      srcW: width,
      srcH: strip.height,
      blend: img.BlendMode.direct,
    );
  }
  return img.encodePng(stored);
}

Future<ui.Image> _decode(JmNetworkImageProvider provider, Uint8List data) async {
  final ui.Codec codec = await provider.instantiateImageCodec(
    data,
    (ui.ImmutableBuffer buffer, {ui.TargetImageSizeCallback? getTargetSize}) => ui.instantiateImageCodecFromBuffer(buffer),
  );
  return (await codec.getNextFrame()).image;
}

Future<void> _expectBands(ui.Image image) async {
  final ByteData pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  for (int band = 0; band < 10; band++) {
    final int y = (band + 0.5) * image.height ~/ 10;
    final int offset = (y * image.width + image.width ~/ 2) * 4;
    final img.ColorRgb8 expected = _band(band);
    expect(pixels.getUint8(offset), closeTo(expected.r, 2), reason: 'band $band red');
    expect(pixels.getUint8(offset + 2), closeTo(expected.b, 2), reason: 'band $band blue');
  }
}

void main() {
  testWidgets('a JM page is restored at full size and at thumbnail size', (WidgetTester tester) async {
    final Uint8List stored = _scrambled(width: 120, height: 1000, strips: 10);
    const String url = 'https://cdn.example.test/media/photos/300000/00001.webp#jmStrips=10';

    await tester.runAsync(() async {
      final ui.Image full = await _decode(JmNetworkImageProvider(url, strips: 10), stored);
      expect((full.width, full.height), (120, 1000));
      await _expectBands(full);

      // A quarter of the bytes: half the width and height, decoded small.
      final ui.Image thumbnail = await _decode(
        JmNetworkImageProvider(url, strips: 10, maxBytes: 120 * 1000 * 4 ~/ 4),
        stored,
      );
      expect((thumbnail.width, thumbnail.height), (60, 500));
      await _expectBands(thumbnail);
    });
  });
}
