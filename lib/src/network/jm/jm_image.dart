import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

/// JM page images are cut into horizontal strips and stored bottom-up.
///
/// The strip count travels with the image url as the fragment
/// `#jmStrips=N`: requests never send the fragment, and everything that
/// keeps the url (reader, thumbnails, download records) keeps the count.
abstract final class JmImage {
  static const String _fragmentKey = 'jmStrips';

  /// Defaults of the JM apps; `/chapter_view_template` gives the current
  /// threshold.
  static const int defaultScrambleId = 220980;
  static const int _fixedTenStripsBelow = 268850;
  static const int _eightStripsFrom = 421926;

  /// Strip count of page [fileName] (with or without extension) of
  /// chapter [chapterId]; 0 means the image is stored as is. GIF pages are
  /// never cut.
  static int stripCount({
    required int scrambleId,
    required int chapterId,
    required String fileName,
  }) {
    if (chapterId < scrambleId || fileName.toLowerCase().endsWith('.gif')) {
      return 0;
    }
    if (chapterId < _fixedTenStripsBelow) {
      return 10;
    }
    final String stem = fileName.contains('.')
        ? fileName.substring(0, fileName.lastIndexOf('.'))
        : fileName;
    final String hex = md5.convert(utf8.encode('$chapterId$stem')).toString();
    final int modulus = chapterId < _eightStripsFrom ? 10 : 8;
    return (hex.codeUnitAt(hex.length - 1) % modulus) * 2 + 2;
  }

  static String pageUrl({
    required String imageDomain,
    required int chapterId,
    required String fileName,
    required int strips,
  }) {
    final String url =
        'https://$imageDomain/media/photos/$chapterId/$fileName';
    return strips > 0 ? '$url#$_fragmentKey=$strips' : url;
  }

  static String coverUrl({required String imageDomain, required int albumId}) =>
      'https://$imageDomain/media/albums/${albumId}_3x4.jpg';

  /// Strip count carried by [url]; 0 when the image needs no restoring.
  static int stripsOf(String url) {
    final int hash = url.indexOf('#');
    if (hash < 0) {
      return 0;
    }
    final Map<String, String> params = Uri.splitQueryString(
      url.substring(hash + 1),
    );
    return int.tryParse(params[_fragmentKey] ?? '') ?? 0;
  }

  /// [url] without the fragment, as sent to the server.
  static String requestUrl(String url) {
    final int hash = url.indexOf('#');
    return hash < 0 ? url : url.substring(0, hash);
  }

  /// Source and destination rows of each strip for an image [height] rows
  /// tall: the remainder rows belong to the first destination strip.
  static List<({int srcY, int dstY, int height})> stripLayout(
    int height,
    int strips,
  ) {
    final int remainder = height % strips;
    final int base = height ~/ strips;
    return <({int srcY, int dstY, int height})>[
      for (int i = 0; i < strips; i++)
        (
          srcY: height - base * (i + 1) - remainder,
          dstY: i == 0 ? 0 : base * i + remainder,
          height: i == 0 ? base + remainder : base,
        ),
    ];
  }

  /// Restores an encoded page image and re-encodes it as JPEG; used for
  /// downloads, where the file must be readable outside the app. Runs in an
  /// isolate: keep it a top-level-style static with plain arguments.
  static Uint8List restoreToJpeg(Uint8List encoded, int strips, {int quality = 92}) {
    final img.Image? source = img.decodeImage(encoded);
    if (source == null) {
      throw const FormatException('Undecodable JM image');
    }
    final img.Image restored = img.Image(
      width: source.width,
      height: source.height,
      numChannels: 3,
    );
    for (final ({int srcY, int dstY, int height}) strip in stripLayout(
      source.height,
      strips,
    )) {
      // dstW/dstH default to the whole source size, which would stretch the
      // strip; copy it 1:1.
      img.compositeImage(
        restored,
        source,
        dstX: 0,
        dstY: strip.dstY,
        dstW: source.width,
        dstH: strip.height,
        srcX: 0,
        srcY: strip.srcY,
        srcW: source.width,
        srcH: strip.height,
        blend: img.BlendMode.direct,
      );
    }
    return img.encodeJpg(restored, quality: quality);
  }
}

/// [JmImage.restoreToJpeg] on a background isolate. A top-level function,
/// so the isolate closure captures only [encoded] and [strips].
Future<Uint8List> restoreJmImageInBackground(Uint8List encoded, int strips) =>
    Isolate.run(() => JmImage.restoreToJpeg(encoded, strips));
