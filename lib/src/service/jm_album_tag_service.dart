import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';

JmAlbumTagService jmAlbumTagService = JmAlbumTagService();

/// The tags of a JM album by namespace, as [JmSource.tagsByNamespace] gives
/// them.
typedef JmAlbumTags = Map<String, List<String>>;

/// Tags of JM albums for their cards in lists.
///
/// JM lists (search, categories, rankings) name an album's author and
/// category only; its tags come with its details. The tags of every album
/// whose details are loaded are kept in a local store, and a list page is
/// given what the store has ([fill]). A card showing an album that is not
/// in the store asks for it ([want]): its details are requested from JM, a
/// few albums at a time, and only while the card is on screen.
class JmAlbumTagService {
  /// Albums requested from JM at once.
  static const int concurrency = 3;

  /// A request that failed is not repeated before this long.
  static const Duration retryAfter = Duration(minutes: 1);

  /// How long the store keeps an album's tags since they were last loaded.
  static const Duration kept = Duration(days: 30);

  /// Set by tests; the JM source by default. The source reports every album
  /// it loads to [record].
  Future<JmAlbum> Function(int albumId)? loadAlbum;

  final StreamController<({int albumId, JmAlbumTags tags})> _loaded =
      StreamController<({int albumId, JmAlbumTags tags})>.broadcast();

  /// Tags as they become known: read from the store for [want], or loaded
  /// from JM by anything.
  Stream<({int albumId, JmAlbumTags tags})> get loaded => _loaded.stream;

  /// Cards waiting by album, oldest first.
  final LinkedHashMap<int, _Request> _requests = LinkedHashMap<int, _Request>();
  final Map<int, DateTime> _failedAt = <int, DateTime>{};
  int _running = 0;

  /// Whether [gallery] is a JM album known from a list only: it has no tags
  /// but its author.
  static bool lacksTags(Gallery gallery) =>
      gallery.galleryUrl.isJM && gallery.tags.keys.every((String namespace) => namespace == 'artist');

  /// Sets [tags] on [gallery], and what follows from them.
  static void apply(Gallery gallery, JmAlbumTags tags) {
    gallery.tags = JmSource.tagMap(tags);
    gallery.language = JmSource.language(tags['tag'] ?? const <String>[]);
  }

  /// Gives the albums of a list page the tags the store has for them.
  Future<void> fill(List<Gallery> gallerys) async {
    final Map<String, List<Gallery>> lacking = <String, List<Gallery>>{};
    for (final Gallery gallery in gallerys) {
      if (lacksTags(gallery)) {
        lacking.putIfAbsent('${gallery.galleryUrl.jmChapterId}', () => <Gallery>[]).add(gallery);
      }
    }
    if (lacking.isEmpty) {
      return;
    }
    try {
      final List<LocalConfig> rows = await localConfigService.readBySubKeys(
        configKey: ConfigEnum.jmAlbumTags,
        subConfigKeys: lacking.keys.toSet(),
      );
      for (final LocalConfig row in rows) {
        final JmAlbumTags? tags = _decode(row.value);
        if (tags != null) {
          for (final Gallery gallery in lacking[row.subConfigKey]!) {
            apply(gallery, tags);
          }
        }
      }
    } catch (e, s) {
      // The cards load what is missing.
      log.error('Read JM album tags failed', e, s);
    }
  }

  /// A card of [albumId] without tags is showing: they come on [loaded],
  /// from the store or from JM. Returns what to hand to [unwant] when the
  /// card goes.
  Object want(int albumId) {
    final _Request? waiting = _requests[albumId];
    if (waiting != null) {
      waiting.cards++;
      return waiting;
    }
    final _Request request = _Request();
    _requests[albumId] = request;
    _read(albumId, request);
    return request;
  }

  /// The card that got [wanted] from [want] left the screen: its album is
  /// not requested unless the request is out already.
  void unwant(int albumId, Object wanted) {
    final _Request? request = _requests[albumId];
    if (request == null || !identical(request, wanted)) {
      // Answered since.
      return;
    }
    request.cards--;
    if (request.cards <= 0 && !request.started) {
      _requests.remove(albumId);
    }
  }

  /// [album]'s details were loaded: its tags go to the store and to the
  /// cards showing it.
  void record(JmAlbum album) {
    final JmAlbumTags tags = JmSource.tagsByNamespace(album);
    _failedAt.remove(album.id);
    _loaded.add((albumId: album.id, tags: tags));
    localConfigService
        .write(configKey: ConfigEnum.jmAlbumTags, subConfigKey: '${album.id}', value: jsonEncode(tags))
        .then<void>((_) {}, onError: (Object e, StackTrace s) => log.error('Store JM album tags failed', e, s));
  }

  Future<void> _read(int albumId, _Request request) async {
    JmAlbumTags? stored;
    try {
      stored = _decode(await localConfigService.read(configKey: ConfigEnum.jmAlbumTags, subConfigKey: '$albumId'));
    } catch (e, s) {
      log.error('Read JM album tags failed', e, s);
    }
    if (!identical(_requests[albumId], request)) {
      return;
    }
    if (stored != null) {
      _requests.remove(albumId);
      _loaded.add((albumId: albumId, tags: stored));
      return;
    }
    final DateTime? failedAt = _failedAt[albumId];
    if (failedAt != null && DateTime.now().difference(failedAt) < retryAfter) {
      _requests.remove(albumId);
      return;
    }
    request.queued = true;
    _pump();
  }

  void _pump() {
    while (_running < concurrency) {
      final int? albumId = _requests.entries
          .where((MapEntry<int, _Request> e) => e.value.queued && !e.value.started)
          .map((MapEntry<int, _Request> e) => e.key)
          .firstOrNull;
      if (albumId == null) {
        return;
      }
      _requests[albumId]!.started = true;
      _running++;
      _load(albumId);
    }
  }

  Future<void> _load(int albumId) async {
    try {
      // The JM source reports the album to [record].
      await (loadAlbum ?? ehRequest.jmSource.album)(albumId);
    } catch (e) {
      _failedAt[albumId] = DateTime.now();
      log.warning('Load tags of JM album $albumId failed', e);
    } finally {
      _requests.remove(albumId);
      _running--;
      _pump();
    }
  }

  static JmAlbumTags? _decode(String? value) {
    if (value == null) {
      return null;
    }
    try {
      return (jsonDecode(value) as Map<String, dynamic>).map(
        (String namespace, dynamic values) => MapEntry<String, List<String>>(namespace, (values as List<dynamic>).cast<String>()),
      );
    } catch (_) {
      return null;
    }
  }
}

class _Request {
  /// Cards waiting for the album.
  int cards = 1;

  /// Not in the store: waiting for its turn to be requested from JM.
  bool queued = false;

  /// Requested from JM.
  bool started = false;
}
