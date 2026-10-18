import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:get/get.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_history_model.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/tachi/tachi_models.dart';
import 'package:jhentai/src/network/tachi/tachi_source.dart';
import 'package:jhentai/src/pages/favorite/favorite_page_logic.dart';
import 'package:jhentai/src/pages/history/history_page_logic.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/series_reading_service.dart';
import 'package:jhentai/src/service/tachi/tachi_extension_service.dart';
import 'package:jhentai/src/service/tachi/tachi_favorite_service.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';

TachiBackupImport tachiBackupImport = TachiBackupImport();

/// Protocol Buffers wire format, as much as a Tachiyomi backup needs.
class ProtoReader {
  ProtoReader(this.bytes, [this.offset = 0, int? end]) : end = end ?? bytes.length;

  final Uint8List bytes;
  int offset;
  final int end;

  bool get done => offset >= end;

  int varint() {
    int result = 0;
    int shift = 0;
    while (true) {
      final int b = bytes[offset++];
      result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) {
        return result;
      }
      shift += 7;
    }
  }

  /// The next field: its number, wire type, and value (an int for varint
  /// and fixed fields, a reader over the bytes for length-delimited ones).
  ({int field, int wire, Object value}) next() {
    final int key = varint();
    final int wire = key & 7;
    switch (wire) {
      case 0:
        return (field: key >> 3, wire: wire, value: varint());
      case 1:
        final int v = ByteData.sublistView(bytes, offset, offset + 8).getInt64(0, Endian.little);
        offset += 8;
        return (field: key >> 3, wire: wire, value: v);
      case 2:
        final int length = varint();
        final ProtoReader inner = ProtoReader(bytes, offset, offset + length);
        offset += length;
        return (field: key >> 3, wire: wire, value: inner);
      case 5:
        final int v = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.little);
        offset += 4;
        return (field: key >> 3, wire: wire, value: v);
      default:
        throw FormatException('Unsupported protobuf wire type $wire');
    }
  }

  String string() => utf8.decode(Uint8List.sublistView(bytes, offset, end), allowMalformed: true);

  /// Repeated varints, packed or one per field.
  static List<int> ints(Object value) {
    if (value is int) {
      return <int>[value];
    }
    final ProtoReader r = value as ProtoReader;
    return <int>[for (; !r.done;) r.varint()];
  }
}

class BackupCategory {
  BackupCategory(this.name, this.order);

  final String name;
  final int order;
}

class BackupChapter {
  String url = '';
  String name = '';
  bool read = false;
  int lastPageRead = 0;
  int dateUpload = 0;
  int sourceOrder = 0;
}

class BackupManga {
  int source = 0;
  String url = '';
  String title = '';
  String? artist;
  String? author;
  String? description;
  final List<String> genre = <String>[];
  int status = 0;
  String? thumbnailUrl;
  int dateAdded = 0;
  final List<BackupChapter> chapters = <BackupChapter>[];
  final List<int> categories = <int>[];
  bool favorite = true;

  /// Chapter URL and when it was last read (ms).
  final List<({String url, int lastRead})> history = <({String url, int lastRead})>[];
}

/// A Tachiyomi, Mihon or Suwayomi backup (`.tachibk`, or the older
/// `.proto.gz`): gzip of a protobuf `Backup`.
class TachiBackup {
  final List<BackupManga> mangas = <BackupManga>[];
  final List<BackupCategory> categories = <BackupCategory>[];
  final Map<int, String> sources = <int, String>{};

  /// Repositories: their base URLs (Mihon up to 0.21, Tachimanga does not
  /// keep them) or the URLs of their `index.min.json` (later Mihon).
  final List<String> repos = <String>[];

  static TachiBackup parse(List<int> file) {
    final Uint8List bytes = Uint8List.fromList(file.length > 2 && file[0] == 0x1f && file[1] == 0x8b ? gzip.decode(file) : file);
    final TachiBackup backup = TachiBackup();
    final ProtoReader r = ProtoReader(bytes);
    while (!r.done) {
      final ({int field, int wire, Object value}) f = r.next();
      switch (f.field) {
        case 1:
          backup.mangas.add(_manga(f.value as ProtoReader));
        case 2:
          backup.categories.add(_category(f.value as ProtoReader));
        case 101:
          final ProtoReader s = f.value as ProtoReader;
          String name = '';
          int id = 0;
          while (!s.done) {
            final ({int field, int wire, Object value}) g = s.next();
            if (g.field == 1) name = (g.value as ProtoReader).string();
            if (g.field == 2) id = g.value as int;
          }
          backup.sources[id] = name;
        case 106:
          final ProtoReader s = f.value as ProtoReader;
          while (!s.done) {
            final ({int field, int wire, Object value}) g = s.next();
            if (g.field == 1) backup.repos.add((g.value as ProtoReader).string());
          }
      }
    }
    return backup;
  }

  static BackupCategory _category(ProtoReader r) {
    String name = '';
    int order = 0;
    while (!r.done) {
      final ({int field, int wire, Object value}) f = r.next();
      if (f.field == 1) name = (f.value as ProtoReader).string();
      if (f.field == 2) order = f.value as int;
    }
    return BackupCategory(name, order);
  }

  static BackupManga _manga(ProtoReader r) {
    final BackupManga m = BackupManga();
    while (!r.done) {
      final ({int field, int wire, Object value}) f = r.next();
      switch (f.field) {
        case 1:
          m.source = f.value as int;
        case 2:
          m.url = (f.value as ProtoReader).string();
        case 3:
          m.title = (f.value as ProtoReader).string();
        case 4:
          m.artist = (f.value as ProtoReader).string();
        case 5:
          m.author = (f.value as ProtoReader).string();
        case 6:
          m.description = (f.value as ProtoReader).string();
        case 7:
          m.genre.add((f.value as ProtoReader).string());
        case 8:
          m.status = f.value as int;
        case 9:
          m.thumbnailUrl = (f.value as ProtoReader).string();
        case 13:
          m.dateAdded = f.value as int;
        case 16:
          m.chapters.add(_chapter(f.value as ProtoReader));
        case 17:
          m.categories.addAll(ProtoReader.ints(f.value));
        case 100:
          m.favorite = f.value as int != 0;
        case 104:
          final ProtoReader h = f.value as ProtoReader;
          String url = '';
          int lastRead = 0;
          while (!h.done) {
            final ({int field, int wire, Object value}) g = h.next();
            if (g.field == 1) url = (g.value as ProtoReader).string();
            if (g.field == 2) lastRead = g.value as int;
          }
          m.history.add((url: url, lastRead: lastRead));
      }
    }
    return m;
  }

  static BackupChapter _chapter(ProtoReader r) {
    final BackupChapter c = BackupChapter();
    while (!r.done) {
      final ({int field, int wire, Object value}) f = r.next();
      switch (f.field) {
        case 1:
          c.url = (f.value as ProtoReader).string();
        case 2:
          c.name = (f.value as ProtoReader).string();
        case 4:
          c.read = f.value as int != 0;
        case 6:
          c.lastPageRead = f.value as int;
        case 8:
          c.dateUpload = f.value as int;
        case 10:
          c.sourceOrder = f.value as int;
      }
    }
    return c;
  }
}

class TachiBackupImportResult {
  int favorites = 0;

  /// Manga of Tachiyomi's local source, whose files are on the device that
  /// made the backup.
  int localSkipped = 0;
  int chaptersRead = 0;
  int chaptersInProgress = 0;
  int history = 0;
  int reposAdded = 0;
  int extensionsInstalled = 0;

  /// Sources in the backup that no installed extension or repository has.
  final Set<String> missingSources = <String>{};

  /// Whether the backup named repositories (Tachimanga's do not).
  bool hadRepos = false;

  String describe() => 'tachiImportSummary'.trParams(<String, String>{
        'favorites': '$favorites',
        'read': '$chaptersRead',
        'progress': '$chaptersInProgress',
        'history': '$history',
        'repos': '$reposAdded',
        'extensions': '$extensionsInstalled',
      }) +
      (localSkipped == 0 ? '' : '\n${'tachiImportLocalSkipped'.trParams(<String, String>{'count': '$localSkipped'})}') +
      (missingSources.isEmpty ? '' : '\n${'tachiImportMissingSources'.tr}: ${missingSources.join(', ')}') +
      (missingSources.isEmpty || hadRepos ? '' : '\n${'tachiImportAddRepos'.tr}');
}

/// Takes a Tachiyomi-family backup into this app: the library becomes
/// Tachiyomi favorites (categories by their order, the eleventh on in the
/// last one), read chapters and pages become read progress, reading history
/// becomes history; the backup's repositories are added and the extensions
/// of its sources installed from them. Manga of the local source are left
/// out.
class TachiBackupImport {
  /// Tachiyomi's local source: files on the device.
  static const int localSourceId = 0;

  Future<TachiBackupImportResult> importFile(String path) async => importBytes(await File(path).readAsBytes());

  Future<TachiBackupImportResult> importBytes(List<int> bytes) async {
    final TachiBackup backup = TachiBackup.parse(bytes);
    final TachiBackupImportResult result = TachiBackupImportResult();
    log.info('Tachiyomi backup: ${backup.mangas.length} manga, ${backup.categories.length} categories, ${backup.sources.length} sources');

    final List<int> categoryOrders = (backup.categories.toList()..sort((a, b) => a.order.compareTo(b.order))).map((c) => c.order).toList();
    final List<({Gallery gallery, int favoriteCategoryIndex, DateTime? favoritedTime})> favorites = [];
    final Map<String, String> progress = <String, String>{};

    for (final BackupManga m in backup.mangas) {
      if (m.source == localSourceId) {
        result.localSkipped++;
        continue;
      }
      final String source = '${m.source}';
      final TachiManga manga = TachiManga(
        url: m.url,
        title: m.title,
        thumbnailUrl: m.thumbnailUrl,
        artist: m.artist,
        author: m.author,
        description: m.description,
        genre: m.genre.join(', '),
        status: m.status,
      );
      final Gallery gallery = ehRequest.tachiSource.galleryOf(source, manga);
      if (m.favorite) {
        final int position = m.categories.isEmpty ? 0 : categoryOrders.indexOf(m.categories.first);
        favorites.add((
          gallery: gallery,
          favoriteCategoryIndex: position < 0 ? 0 : position.clamp(0, 9),
          favoritedTime: m.dateAdded > 0 ? DateTime.fromMillisecondsSinceEpoch(m.dateAdded) : null,
        ));
      }

      // Reading order is oldest first; the source lists newest first (order 0).
      final List<BackupChapter> chapters = m.chapters.toList()..sort((a, b) => b.sourceOrder.compareTo(a.sourceOrder));
      final List<int> ids = <int>[];
      for (final BackupChapter c in chapters) {
        final GalleryUrl url = GalleryUrl.tachiChapter(source, m.url, c.url);
        ids.add(TachiSource.idOf(url));
        if (c.read) {
          progress['${url.gid}'] = SeriesReadingService.markedReadValue;
          result.chaptersRead++;
        } else if (c.lastPageRead > 0) {
          progress['${url.gid}'] = '${c.lastPageRead}';
          result.chaptersInProgress++;
        }
      }
      // Mihon keeps every chapter, Tachimanga only those read or begun: the
      // chapters are the manga's when their orders leave no gap, else they
      // are learnt from its site when it is opened, rather than a part being
      // shown as the whole, read to the end.
      if (ids.length > 1 && _withoutGaps(chapters)) {
        progress[tachiReadingService.keyOfChapters(TachiSource.idOf(gallery.galleryUrl))] = ids.join(',');
      }

      final int lastRead = m.history.fold<int>(0, (int a, ({String url, int lastRead}) h) => h.lastRead > a ? h.lastRead : a);
      if (lastRead > 0) {
        await historyService.recordAt(
          GalleryHistoryModel(
            galleryUrl: gallery.galleryUrl,
            title: gallery.title,
            category: gallery.category,
            coverUrl: gallery.cover.url,
            pageCount: 0,
            rating: 0,
            language: '',
            uploader: gallery.uploader ?? '',
            publishTime: '',
            isExpunged: false,
            tags: <String>[for (final String g in m.genre) 'tag:$g'],
          ),
          SyncTimeUtil.format(DateTime.fromMillisecondsSinceEpoch(lastRead, isUtc: true)),
        );
        result.history++;
      }
    }

    await tachiFavoriteService.addFavorites(favorites);
    result.favorites = favorites.length;
    if (progress.isNotEmpty) {
      await readProgressService.writeProgressValues(progress);
    }

    result.hadRepos = backup.repos.isNotEmpty;
    for (final String repo in backup.repos) {
      final int before = tachiExtensionService.repos.length;
      await tachiExtensionService.addRepo(repo);
      result.reposAdded += tachiExtensionService.repos.length - before;
    }
    await _installExtensionsOf(backup, result);

    // Lists already open show what came in.
    if (Get.isRegistered<FavoritePageLogic>()) {
      await Get.find<FavoritePageLogic>().reloadLocalSourceFavoriteGallerys();
    }
    if (Get.isRegistered<HistoryPageLogic>()) {
      await Get.find<HistoryPageLogic>().handleClearAndRefresh();
    }
    return result;
  }

  /// Whether [chapters], newest last, are numbered 0 to n - 1 by their order
  /// in the source.
  static bool _withoutGaps(List<BackupChapter> chapters) {
    for (int i = 0; i < chapters.length; i++) {
      if (chapters[i].sourceOrder != chapters.length - 1 - i) {
        return false;
      }
    }
    return true;
  }

  Future<void> _installExtensionsOf(TachiBackup backup, TachiBackupImportResult result) async {
    final Set<String> wanted = <String>{
      for (final BackupManga m in backup.mangas)
        if (m.source != localSourceId) '${m.source}',
    };
    await tachiExtensionService.refreshInstalled();
    await tachiExtensionService.refreshRepos();
    final Set<String> have = tachiExtensionService.installed.expand((e) => e.sources).map((s) => s.id).toSet();
    final List<TachiRepoExtension> toInstall = <TachiRepoExtension>[];
    for (final String id in wanted.difference(have)) {
      final TachiRepoExtension? offer = tachiExtensionService.offered.firstWhereOrNull((e) => e.sources.any((s) => s.id == id));
      if (offer == null) {
        result.missingSources.add(backup.sources[int.parse(id)] ?? id);
      } else if (!toInstall.any((e) => e.pkg == offer.pkg)) {
        toInstall.add(offer);
      }
    }
    for (final TachiRepoExtension extension in toInstall) {
      try {
        await tachiExtensionService.install(extension);
        result.extensionsInstalled++;
      } catch (e) {
        log.error('Install ${extension.pkg} from backup failed', e);
        result.missingSources.addAll(extension.sources.map((s) => s.name));
      }
    }
  }
}
