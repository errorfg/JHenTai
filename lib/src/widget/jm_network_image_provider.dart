import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:extended_image_library/src/network/network_image_io.dart' as network_image_io;
import 'package:flutter/painting.dart';
import 'package:jhentai/src/network/jm/jm_image.dart';

/// Loads a JM page image and puts its strips back in order before display.
///
/// Resizing happens here too: the image is decoded at the size [maxBytes]
/// allows, then its strips are drawn in order. [maxBytes] is part of
/// equality so a thumbnail never serves a full-size request.
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
    final ui.ImmutableBuffer encoded = await ui.ImmutableBuffer.fromUint8List(data);
    final ui.ImageDescriptor source = await ui.ImageDescriptor.encoded(encoded);
    final int width = source.width;
    final int height = source.height;
    final int? limit = maxBytes;
    final double scale = limit != null && width * height * 4 > limit ? math.sqrt(limit / (width * height * 4)) : 1;
    final int targetWidth = math.max(1, (width * scale).floor());
    final int targetHeight = math.max(1, (height * scale).floor());

    // A thumbnail is decoded at its own size: a JM page can be several
    // megapixels, and decoding it in full for a thumbnail is most of the
    // work.
    final ui.Codec codec = scale < 1
        ? await source.instantiateCodec(targetWidth: targetWidth, targetHeight: targetHeight)
        : await source.instantiateCodec();
    final ui.Image image = (await codec.getNextFrame()).image;
    codec.dispose();
    source.dispose();
    encoded.dispose();

    // Strip edges are computed on the stored height, then scaled to the
    // decoded image.
    final double sourceScale = image.height / height;
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
        Rect.fromLTWH(0, strip.srcY * sourceScale, image.width.toDouble(), strip.height * sourceScale),
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
