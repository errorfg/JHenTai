import 'dart:convert';

import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';

PendingSyncTracker pendingSyncTracker = PendingSyncTracker();

/// Immutable, process-local snapshot of pending keys and their mutation
/// generations. Generations deliberately are not persisted: after a restart
/// every persisted pending key receives a fresh generation before it can be
/// snapshotted again.
class PendingSyncSnapshotToken {
  PendingSyncSnapshotToken._({
    required Map<int, int> historyGenerations,
    required Map<String, int> progressGenerations,
  }) : _historyGenerations = Map<int, int>.unmodifiable(historyGenerations),
       _progressGenerations = Map<String, int>.unmodifiable(
         progressGenerations,
       );

  final Map<int, int> _historyGenerations;
  final Map<String, int> _progressGenerations;

  Set<int> get historyGids => Set<int>.unmodifiable(_historyGenerations.keys);

  Set<String> get progressKeys =>
      Set<String>.unmodifiable(_progressGenerations.keys);
}

/// Tracks which locally-originated rows still need to be pushed to the cloud.
///
/// Push eligibility used to be derived from row timestamps compared against a
/// cursor, but row timestamps are LWW data shared across devices: applying a
/// future-dated row from a device with a skewed clock would advance the cursor
/// past subsequent genuine local writes, silently dropping them. An explicit
/// dirty set decouples "what changed here" from "when it happened".
///
/// Only user-originated write paths mark rows pending (recording history,
/// updating read progress). Rows applied FROM the cloud are deliberately not
/// marked - they already exist remotely.
///
/// The in-memory sets are authoritative; persistence is write-through and
/// serialized so interleaved marks cannot lose each other's updates. Losing
/// the persisted state (crash between mark and flush) at worst delays a row
/// until the next full push.
class PendingSyncTracker {
  final Set<int> _historyGids = {};
  final Set<String> _progressKeys = {};
  final Map<int, int> _historyGenerations = <int, int>{};
  final Map<String, int> _progressGenerations = <String, int>{};
  int _nextGeneration = 0;

  Future<void>? _loadFuture;
  Future<void> _persistChain = Future.value();

  Future<void> ensureLoaded() {
    return _loadFuture ??= _load();
  }

  Future<void> _load() async {
    try {
      String? raw = await localConfigService.read(
        configKey: ConfigEnum.oplogPendingPush,
      );
      if (raw == null || raw.isEmpty) {
        return;
      }
      Map<String, dynamic> json = jsonDecode(raw);
      _historyGids.addAll((json['history'] as List? ?? []).cast<int>());
      _progressKeys.addAll(
        (json['readProgress'] as List? ?? []).cast<String>(),
      );
      for (final int gid in _historyGids) {
        _historyGenerations[gid] = ++_nextGeneration;
      }
      for (final String key in _progressKeys) {
        _progressGenerations[key] = ++_nextGeneration;
      }
    } catch (e) {
      log.warning('PendingSyncTracker: failed to load persisted state', e);
    }
  }

  Future<void> markHistoryPending(int gid) async {
    await ensureLoaded();
    final bool added = _historyGids.add(gid);
    _historyGenerations[gid] = ++_nextGeneration;
    if (added) {
      await _persist();
    }
  }

  Future<void> markProgressPending(String subConfigKey) async {
    await markProgressPendingAll(<String>[subConfigKey]);
  }

  /// Add multiple progress keys with one persisted tracker update.
  Future<void> markProgressPendingAll(Iterable<String> subConfigKeys) async {
    await ensureLoaded();
    bool added = false;
    for (final String key in subConfigKeys.toSet()) {
      added = _progressKeys.add(key) || added;
      _progressGenerations[key] = ++_nextGeneration;
    }
    if (added) {
      await _persist();
    }
  }

  /// Snapshot pending keys together with their current mutation generations.
  /// A successful push must be acknowledged with [removePushedSnapshot], so a
  /// key marked again while the push is in flight survives for the next push.
  Future<PendingSyncSnapshotToken> snapshotToken() async {
    await ensureLoaded();
    return PendingSyncSnapshotToken._(
      historyGenerations: <int, int>{
        for (final int gid in _historyGids) gid: _historyGenerations[gid]!,
      },
      progressGenerations: <String, int>{
        for (final String key in _progressKeys) key: _progressGenerations[key]!,
      },
    );
  }

  /// Set-only compatibility snapshot. New push code should use
  /// [snapshotToken] so same-key re-marks can be distinguished.
  Future<(Set<int>, Set<String>)> snapshot() async {
    final PendingSyncSnapshotToken token = await snapshotToken();
    return (token.historyGids, token.progressKeys);
  }

  /// Remove only keys whose generation still matches [snapshot].
  Future<void> removePushedSnapshot(PendingSyncSnapshotToken snapshot) async {
    await ensureLoaded();
    bool changed = false;

    for (final MapEntry<int, int> entry
        in snapshot._historyGenerations.entries) {
      if (_historyGenerations[entry.key] == entry.value) {
        _historyGids.remove(entry.key);
        _historyGenerations.remove(entry.key);
        changed = true;
      }
    }
    for (final MapEntry<String, int> entry
        in snapshot._progressGenerations.entries) {
      if (_progressGenerations[entry.key] == entry.value) {
        _progressKeys.remove(entry.key);
        _progressGenerations.remove(entry.key);
        changed = true;
      }
    }

    if (changed) {
      await _persist();
    }
  }

  /// Legacy set-only removal retained for compatibility. It cannot distinguish
  /// a same-key re-mark; sync push code must use [removePushedSnapshot].
  Future<void> removePushed(
    Set<int> historyGids,
    Set<String> progressKeys,
  ) async {
    await ensureLoaded();
    _historyGids.removeAll(historyGids);
    _progressKeys.removeAll(progressKeys);
    _historyGenerations.removeWhere((int key, _) => historyGids.contains(key));
    _progressGenerations.removeWhere(
      (String key, _) => progressKeys.contains(key),
    );
    await _persist();
  }

  Future<void> clearAll() async {
    await ensureLoaded();
    _historyGids.clear();
    _progressKeys.clear();
    _historyGenerations.clear();
    _progressGenerations.clear();
    await _persist();
  }

  /// Write-through persistence, serialized to keep the stored JSON consistent
  /// with the in-memory sets under interleaved async callers.
  Future<void> _persist() {
    String encoded = jsonEncode({
      'history': _historyGids.toList(),
      'readProgress': _progressKeys.toList(),
    });
    _persistChain = _persistChain.then((_) async {
      try {
        await localConfigService.write(
          configKey: ConfigEnum.oplogPendingPush,
          value: encoded,
        );
      } catch (e) {
        log.warning('PendingSyncTracker: persist failed', e);
      }
    });
    return _persistChain;
  }
}
