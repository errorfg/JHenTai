import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:extended_image_library/src/network/network_image_io.dart' as network_image_io;
import 'package:flutter/painting.dart';
import 'package:jhentai/src/network/jm/jm_image.dart';

/// Loads a JM page image and puts its strips back in order before display.
///
/// Resizing happens here too, for thumbnails ([maxBytes]): JM pages are
/// large and full of screentones, which need an averaging downscale. [maxBytes] is part
/// of equality so a thumbnail never serves a full-size request.
class JmNetworkImageProvider extends network_image_io.ExtendedNetworkImageProvider {
  JmNetworkImageProvider(
    String url, {
    required this.strips,
    this.maxBytes,
    super.headers,
    super.cacheKey,
    super.cache,
    super.printError,
  }) : super(JmImage.requestUrl(url));

  final int strips;
  final int? maxBytes;

  @override
  Future<ui.Codec> instantiateImageCodec(Uint8List data, ImageDecoderCallback decode) async {
    final ui.Codec source = await ui.instantiateImageCodec(data);
    final ui.Image image = (await source.getNextFrame()).image;
    source.dispose();

    final int width = image.width;
    final int height = image.height;
    final int? limit = maxBytes;
    final double scale = limit != null && width * height * 4 > limit ? math.sqrt(limit / (width * height * 4)) : 1;
    final int targetWidth = math.max(1, (width * scale).floor());
    final int targetHeight = math.max(1, (height * scale).floor());

    // The strips back in order, pixel for pixel.
    ui.Image current = await _paint(width, height, (Canvas canvas) {
      final Paint paint = Paint()..filterQuality = FilterQuality.none;
      for (final ({int srcY, int dstY, int height}) strip in JmImage.stripLayout(height, strips)) {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, strip.srcY.toDouble(), width.toDouble(), strip.height.toDouble()),
          Rect.fromLTWH(0, strip.dstY.toDouble(), width.toDouble(), strip.height.toDouble()),
          paint,
        );
      }
    });
    image.dispose();

    // Thumbnails: halve while at least twice the target. Bilinear sampling
    // at exactly half size averages each 2x2 block, so fine screentones
    // turn grey instead of into moiré, whatever the renderer does with
    // mipmaps. The last step is under 2x.
    while (current.width >= targetWidth * 2 && current.height >= targetHeight * 2) {
      current = await _resize(current, current.width ~/ 2, current.height ~/ 2);
    }
    if (current.width != targetWidth || current.height != targetHeight) {
      current = await _resize(current, targetWidth, targetHeight);
    }

    final ByteData? pixels = await current.toByteData(format: ui.ImageByteFormat.rawRgba);
    final int outWidth = current.width;
    final int outHeight = current.height;
    current.dispose();
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(pixels!.buffer.asUint8List());
    final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: outWidth,
      height: outHeight,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    return descriptor.instantiateCodec();
  }

  /// [image] drawn at [width] x [height] with bilinear sampling; disposes
  /// [image].
  static Future<ui.Image> _resize(ui.Image image, int width, int height) async {
    final ui.Image resized = await _paint(width, height, (Canvas canvas) {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..filterQuality = FilterQuality.low,
      );
    });
    image.dispose();
    return resized;
  }

  static Future<ui.Image> _paint(int width, int height, void Function(Canvas canvas) draw) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    draw(Canvas(recorder));
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(width, height);
    picture.dispose();
    return image;
  }

  @override
  bool operator ==(Object other) =>
      other is JmNetworkImageProvider && super == other && other.strips == strips && other.maxBytes == maxBytes;

  @override
  int get hashCode => Object.hash(super.hashCode, strips, maxBytes);
}
