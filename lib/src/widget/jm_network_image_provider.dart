import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:extended_image_library/src/network/network_image_io.dart' as network_image_io;
import 'package:flutter/painting.dart';
import 'package:jhentai/src/network/jm/jm_image.dart';

/// Loads a JM page image and puts its strips back in order before display.
///
/// Resizing happens here too, while the strips are drawn, because a resize
/// after restoring could not reuse the decode-time size hint. [maxBytes]
/// is part of equality so a thumbnail never serves a full-size request.
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

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final Paint paint = Paint()
      ..isAntiAlias = false
      ..filterQuality = FilterQuality.medium;
    for (final ({int srcY, int dstY, int height}) strip in JmImage.stripLayout(height, strips)) {
      // Integer destination edges: adjacent strips meet without a gap.
      final double top = (strip.dstY * scale).roundToDouble();
      final double bottom = ((strip.dstY + strip.height) * scale).roundToDouble();
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, strip.srcY.toDouble(), width.toDouble(), strip.height.toDouble()),
        Rect.fromLTRB(0, top, targetWidth.toDouble(), bottom),
        paint,
      );
    }
    final ui.Picture picture = recorder.endRecording();
    final ui.Image restored = await picture.toImage(targetWidth, targetHeight);
    picture.dispose();
    image.dispose();

    final ByteData? pixels = await restored.toByteData(format: ui.ImageByteFormat.rawRgba);
    restored.dispose();
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(pixels!.buffer.asUint8List());
    final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: targetWidth,
      height: targetHeight,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    return descriptor.instantiateCodec();
  }

  @override
  bool operator ==(Object other) =>
      other is JmNetworkImageProvider && super == other && other.strips == strips && other.maxBytes == maxBytes;

  @override
  int get hashCode => Object.hash(super.hashCode, strips, maxBytes);
}
