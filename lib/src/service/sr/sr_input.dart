import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart' show getCrc32;
import 'package:jhentai/src/network/jm/jm_image.dart';

/// A page ready for an upscaler program: PNG, JM strips back in order.
class SrInput {
  const SrInput({required this.png, required this.width, required this.height});

  final Uint8List png;
  final int width;
  final int height;
}

/// Decodes [encoded] (any format the app shows), puts the [strips] of a JM
/// page back in order and encodes it as PNG, which every upscaler program
/// reads on every platform whatever the source was called or stored as.
/// The PNG has no alpha channel: given one, the programs upscale it as
/// well and write a PNG whatever output was asked for.
///
/// Null when the image is animated, or when what is shown of it as a page
/// is at least [maxWidth] pixels wide (0: no limit): such pages are large
/// enough as they are. With [splitWide] (the reader splits wide pages) a
/// page wider than tall is shown in halves, so half its width counts.
Future<SrInput?> prepareSrInput(Uint8List encoded, {int strips = 0, int maxWidth = 0, bool splitWide = false}) async {
  final ui.Codec codec = await ui.instantiateImageCodec(encoded);
  if (codec.frameCount > 1) {
    codec.dispose();
    return null;
  }
  ui.Image image = (await codec.getNextFrame()).image;
  codec.dispose();
  final int width = image.width;
  final int height = image.height;
  if (_wideEnough(width, height, maxWidth: maxWidth, splitWide: splitWide)) {
    image.dispose();
    return null;
  }

  if (strips > 0) {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    final ui.Paint paint = ui.Paint()..filterQuality = ui.FilterQuality.none;
    for (final ({int srcY, int dstY, int height}) strip in JmImage.stripLayout(height, strips)) {
      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(0, strip.srcY.toDouble(), width.toDouble(), strip.height.toDouble()),
        ui.Rect.fromLTWH(0, strip.dstY.toDouble(), width.toDouble(), strip.height.toDouble()),
        paint,
      );
    }
    final ui.Picture picture = recorder.endRecording();
    final ui.Image restored = await picture.toImage(width, height);
    picture.dispose();
    image.dispose();
    image = restored;
  }

  final ByteData? rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  if (rgba == null) {
    return null;
  }
  return SrInput(png: encodeOpaquePng(rgba.buffer.asUint8List(), width, height), width: width, height: height);
}

/// A page as sent to an upscaling service: the file itself when the service
/// reads it as it is (JPEG, PNG, WebP; it puts transparent parts on white
/// as [encodeOpaquePng] does), which is far smaller than the PNG; else, as
/// for the programs here, the PNG of [prepareSrInput] (a JM page with its
/// strips back in order, any other format).
///
/// Null for the pages [prepareSrInput] leaves out.
Future<Uint8List?> prepareSrUpload(Uint8List encoded, {int strips = 0, int maxWidth = 0, bool splitWide = false}) async {
  if (strips > 0 || !_readByService(encoded)) {
    return (await prepareSrInput(encoded, strips: strips, maxWidth: maxWidth, splitWide: splitWide))?.png;
  }
  // The size and the frame count, without decoding the page.
  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
  try {
    final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (_wideEnough(descriptor.width, descriptor.height, maxWidth: maxWidth, splitWide: splitWide)) {
      descriptor.dispose();
      return null;
    }
    final ui.Codec codec = await descriptor.instantiateCodec();
    final bool animated = codec.frameCount > 1;
    codec.dispose();
    return animated ? null : encoded;
  } finally {
    buffer.dispose();
  }
}

/// Whether a page of [width] x [height] is shown at least [maxWidth] wide.
/// Split, an image wider than tall (the reader's spread, see SpreadPages)
/// is shown a half at a time.
bool _wideEnough(int width, int height, {required int maxWidth, required bool splitWide}) {
  final int shown = splitWide && width > height ? width ~/ 2 : width;
  return maxWidth > 0 && shown >= maxWidth;
}

bool _readByService(Uint8List bytes) {
  bool startsWith(List<int> magic, [int offset = 0]) {
    if (bytes.length < offset + magic.length) {
      return false;
    }
    for (int i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) {
        return false;
      }
    }
    return true;
  }

  return startsWith(const <int>[0xFF, 0xD8, 0xFF]) ||
      startsWith(const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) ||
      (startsWith('RIFF'.codeUnits) && startsWith('WEBP'.codeUnits, 8));
}

/// An RGB PNG of [width] x [height] premultiplied RGBA pixels, shown on
/// white where they are transparent. Compressed lightly: the file is read
/// once by the upscaler and deleted.
Uint8List encodeOpaquePng(Uint8List rgba, int width, int height) {
  // Scanlines: a filter byte (0, none) and the RGB bytes of the row.
  final int stride = width * 3 + 1;
  final Uint8List raw = Uint8List(stride * height);
  int source = 0;
  for (int y = 0; y < height; y++) {
    int target = y * stride + 1;
    for (int x = 0; x < width; x++) {
      final int white = 255 - rgba[source + 3];
      raw[target] = rgba[source] + white;
      raw[target + 1] = rgba[source + 1] + white;
      raw[target + 2] = rgba[source + 2] + white;
      source += 4;
      target += 3;
    }
  }

  final BytesBuilder png = BytesBuilder(copy: false)
    ..add(const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final Uint8List body = Uint8List(4 + data.length)
      ..setRange(0, 4, type.codeUnits)
      ..setRange(4, 4 + data.length, data);
    png
      ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
      ..add(body)
      ..add((ByteData(4)..setUint32(0, getCrc32(body))).buffer.asUint8List());
  }

  final ByteData header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 2); // colour type: RGB
  chunk('IHDR', header.buffer.asUint8List());
  chunk('IDAT', ZLibCodec(level: 1).encode(raw));
  chunk('IEND', const <int>[]);
  return png.toBytes();
}
