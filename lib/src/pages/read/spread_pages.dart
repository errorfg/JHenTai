import 'dart:async';
import 'dart:convert';

import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/model/read_page_info.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';

import 'read_page_state.dart';

/// Which images of the books being read are wider than tall (two pages
/// scanned as one), as found when they load. Kept per book, so the next
/// reading knows them before they load. The double-column layout gives such
/// an image a page of its own; splitting wide pages shows each half as a
/// page (single page) or the halves one above the other (top to bottom).
class SpreadPages {
  SpreadPages(this._state);

  final ReadPageState _state;
  List<bool> _flags = <bool>[];
  final Completer<void> _loaded = Completer<void>();

  /// Done once what earlier readings found is known.
  Future<void> get loaded => _loaded.future;

  bool get isLoaded => _loaded.isCompleted;

  int get length => _flags.length;

  bool operator [](int index) => index >= 0 && index < _flags.length && _flags[index];

  /// Reads what was found for the books being read; once, by the reader.
  Future<void> load() async {
    if (_loaded.isCompleted) {
      return;
    }
    _flags = List<bool>.filled(_state.pageCount, false, growable: true);
    try {
      for (final ReadSegment segment in List<ReadSegment>.of(_state.segments)) {
        await _read(segment);
      }
    } finally {
      _loaded.complete();
    }
  }

  /// Pages of another book were added after the last.
  Future<void> onPagesAppended() async {
    final int known = _flags.length;
    _flags.addAll(List<bool>.filled(_state.pageCount - known, false));
    if (!_loaded.isCompleted) {
      return;
    }
    for (final ReadSegment segment in _state.segments.where((ReadSegment s) => s.start >= known)) {
      await _read(segment);
    }
  }

  /// The pages of [segment] were put before the first book.
  Future<void> onPagesPrepended(ReadSegment segment) async {
    _flags.insertAll(0, List<bool>.filled(segment.pageCount, false));
    if (!_loaded.isCompleted) {
      return;
    }
    await _read(segment);
  }

  /// Records that image [index] is wider than tall; false when that was
  /// known, or before [load] finished.
  bool mark(int index) {
    if (!_loaded.isCompleted || index < 0 || index >= _flags.length || _flags[index]) {
      return false;
    }
    _flags[index] = true;
    final ReadSegment segment = _state.segmentAt(index);
    unawaited(
      localConfigService.write(
        configKey: ConfigEnum.isSpreadPage,
        subConfigKey: segment.info.readProgressRecordStorageKey,
        value: jsonEncode(<int>[for (int i = 0; i < segment.pageCount; i++) _flags[segment.start + i] ? 1 : 0]),
      ),
    );
    return true;
  }

  Future<void> _read(ReadSegment segment) async {
    final String? legacy = segment.info.legacyProgressKey;
    final String? text = await localConfigService.read(configKey: ConfigEnum.isSpreadPage, subConfigKey: segment.info.readProgressRecordStorageKey) ??
        (legacy == null ? null : await localConfigService.read(configKey: ConfigEnum.isSpreadPage, subConfigKey: legacy));
    if (text == null) {
      return;
    }
    try {
      final List<dynamic> found = jsonDecode(text) as List<dynamic>;
      for (int i = 0; i < found.length && i < segment.pageCount && segment.start + i < _flags.length; i++) {
        if (found[i] == 1) {
          _flags[segment.start + i] = true;
        }
      }
    } on FormatException catch (e) {
      log.warning('Unreadable spread pages of ${segment.info.readProgressRecordStorageKey}', e);
    }
  }
}

/// Which part of an image a page shows.
enum ImagePart {
  whole,

  /// The half read first: the right one from right to left.
  first,
  second,
}

/// The pages of the single-page layout: one per image, two for an image
/// that is split.
class PageParts {
  PageParts(List<bool> split) : _split = List<bool>.unmodifiable(split) {
    for (int image = 0; image < split.length; image++) {
      _firstPage.add(_image.length);
      _image.add(image);
      if (split[image]) {
        _image.add(image);
      }
    }
  }

  /// One page per image.
  PageParts.unsplit(int imageCount) : this(List<bool>.filled(imageCount, false));

  final List<bool> _split;
  final List<int> _image = <int>[];
  final List<int> _firstPage = <int>[];

  int get length => _image.length;

  /// Whether these pages split the images [split] says.
  bool splitAs(List<bool> split) {
    if (split.length != _split.length) {
      return false;
    }
    for (int i = 0; i < split.length; i++) {
      if (split[i] != _split[i]) {
        return false;
      }
    }
    return true;
  }

  bool isSplit(int image) => image >= 0 && image < _split.length && _split[image];

  int imageOf(int page) => _image.isEmpty ? 0 : _image[page.clamp(0, _image.length - 1)];

  int firstPageOf(int image) => _firstPage.isEmpty ? 0 : _firstPage[image.clamp(0, _firstPage.length - 1)];

  ImagePart partOf(int page) {
    final int image = imageOf(page);
    if (!isSplit(image)) {
      return ImagePart.whole;
    }
    return page.clamp(0, length - 1) == firstPageOf(image) ? ImagePart.first : ImagePart.second;
  }

  /// The page showing [part] of [image].
  int pageOf(int image, ImagePart part) => firstPageOf(image) + (part == ImagePart.second && isSplit(image) ? 1 : 0);
}
