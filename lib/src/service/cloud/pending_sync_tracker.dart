import 'dart:convert';

import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';

PendingSyncTracker pendingSyncTracker = PendingSyncTracker();

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

  Future<void>? _loadFuture;
  Future<void> _persistChain = Future.value();

  Future<void> ensureLoaded() {
    return _loadFuture ??= _load();
  }

  Future<void> _load() async {
    try {
      String? raw = await localConfigService.read(configKey: ConfigEnum.oplogPendingPush);
      if (raw == null || raw.isEmpty) {
        return;
      }
      Map<String, dynamic> json = jsonDecode(raw);
      _historyGids.addAll((json['history'] as List? ?? []).cast<int>());
      _progressKeys.addAll((json['readProgress'] as List? ?? []).cast<String>());
    } catch (e) {
      log.warning('PendingSyncTracker: failed to load persisted state', e);
    }
  }

  Future<void> markHistoryPending(int gid) async {
    await ensureLoaded();
    if (_historyGids.add(gid)) {
      _persist();
    }
  }

  Future<void> markProgressPending(String subConfigKey) async {
    await ensureLoaded();
    if (_progressKeys.add(subConfigKey)) {
      _persist();
    }
  }

  /// Stable snapshots for one push round.
  Future<(Set<int>, Set<String>)> snapshot() async {
    await ensureLoaded();
    return (Set<int>.of(_historyGids), Set<String>.of(_progressKeys));
  }

  /// Remove ids that were successfully pushed. Ids marked after the snapshot
  /// was taken survive for the next round.
  Future<void> removePushed(Set<int> historyGids, Set<String> progressKeys) async {
    await ensureLoaded();
    _historyGids.removeAll(historyGids);
    _progressKeys.removeAll(progressKeys);
    _persist();
  }

  Future<void> clearAll() async {
    await ensureLoaded();
    _historyGids.clear();
    _progressKeys.clear();
    _persist();
  }

  /// Write-through persistence, serialized to keep the stored JSON consistent
  /// with the in-memory sets under interleaved async callers.
  void _persist() {
    String encoded = jsonEncode({
      'history': _historyGids.toList(),
      'readProgress': _progressKeys.toList(),
    });
    _persistChain = _persistChain.then((_) async {
      try {
        await localConfigService.write(configKey: ConfigEnum.oplogPendingPush, value: encoded);
      } catch (e) {
        log.warning('PendingSyncTracker: persist failed', e);
      }
    });
  }
}
