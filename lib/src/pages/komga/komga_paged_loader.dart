import 'package:flutter/foundation.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';

/// Loads a server-paged list on demand.
///
/// Items are de-duplicated by id, because offset paging over a sort with
/// ties can repeat an item across pages. A failed page keeps what is already
/// loaded and can be retried. [stopWhen] ends the list early at the first
/// matching item (for example the first one older than the last visit).
class KomgaPagedLoader<T> extends ChangeNotifier {
  KomgaPagedLoader({
    required this.fetch,
    required this.idOf,
    this.stopWhen,
    this.onPageLoaded,
  });

  final Future<KomgaPageResult<T>> Function(int page) fetch;
  final String Function(T item) idOf;
  final bool Function(T item)? stopWhen;
  final Future<void> Function(List<T> items)? onPageLoaded;

  final List<T> items = <T>[];
  final Set<String> _ids = <String>{};
  int _nextPage = 0;
  int _generation = 0;
  bool _disposed = false;

  bool hasMore = true;
  bool loading = false;
  Object? error;
  bool loadedOnce = false;

  bool get isEmpty => loadedOnce && items.isEmpty && !hasMore;

  Future<void> refresh() {
    _generation++;
    items.clear();
    _ids.clear();
    _nextPage = 0;
    hasMore = true;
    loading = false;
    error = null;
    loadedOnce = false;
    _notify();
    return loadMore();
  }

  Future<void> loadMore() async {
    if (loading || !hasMore) {
      return;
    }
    final int generation = _generation;
    loading = true;
    error = null;
    _notify();
    try {
      final KomgaPageResult<T> page = await fetch(_nextPage);
      if (generation != _generation) {
        return;
      }
      final List<T> added = <T>[];
      bool stopped = false;
      for (final T item in page.content) {
        if (stopWhen?.call(item) ?? false) {
          stopped = true;
          break;
        }
        if (_ids.add(idOf(item))) {
          added.add(item);
        }
      }
      items.addAll(added);
      _nextPage++;
      hasMore = !stopped && !page.isLast && page.content.isNotEmpty;
      loadedOnce = true;
      if (added.isNotEmpty) {
        await onPageLoaded?.call(added);
      }
    } catch (e) {
      if (generation == _generation) {
        error = e;
      }
    } finally {
      if (generation == _generation) {
        loading = false;
        _notify();
      }
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
