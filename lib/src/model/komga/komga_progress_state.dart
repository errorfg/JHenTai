import 'dart:math';

import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';

/// Read progress as Komga stores it. [page] is 1-based; a null [page] means
/// the book has no progress on the server (unread).
class KomgaServerProgress {
  const KomgaServerProgress({
    required this.page,
    required this.completed,
    this.readDate,
  });

  static const KomgaServerProgress none = KomgaServerProgress(
    page: null,
    completed: false,
  );

  final int? page;
  final bool completed;
  final DateTime? readDate;

  bool get hasProgress => page != null;

  factory KomgaServerProgress.fromBook(KomgaBook book) {
    final KomgaReadProgress? progress = book.readProgress;
    if (progress == null) {
      return none;
    }
    return KomgaServerProgress(
      page: progress.page,
      completed: progress.completed,
      readDate:
          progress.readDate ?? progress.lastModifiedDate ?? progress.createdDate,
    );
  }

  /// The server state after JHenTai pushes [localValue]. Komga marks a book
  /// completed when the reported page equals its page count.
  factory KomgaServerProgress.afterPush(String localValue, int pageCount) {
    final int? index = int.tryParse(localValue);
    if (index == null) {
      return none;
    }
    return KomgaServerProgress(
      page: index + 1,
      completed: index + 1 >= pageCount,
    );
  }

  /// The local progress value this state maps to: a 0-based page index, or
  /// an empty string for unread.
  String toLocalValue(int pageCount) {
    final int lastIndex = max(pageCount - 1, 0);
    if (page == null) {
      return '';
    }
    if (completed) {
      return lastIndex.toString();
    }
    return min(max(page! - 1, 0), lastIndex).toString();
  }
}

/// A raw local progress record. An empty [value] is the unread marker, which
/// travels through cloud sync like any other progress value.
class KomgaLocalProgress {
  const KomgaLocalProgress({required this.value, required this.utime});

  final String value;

  /// Canonical UTC timestamp string as stored in the database.
  final String utime;

  DateTime? get time => SyncTimeUtil.tryParse(utime);
}

/// The last state both sides were known to agree on. Stored per book on this
/// device only; it is never cloud-synced.
class KomgaProgressBase {
  const KomgaProgressBase({
    required this.serverPage,
    required this.serverCompleted,
    required this.localValue,
    required this.localUtime,
  });

  factory KomgaProgressBase.agreed({
    required KomgaServerProgress server,
    required KomgaLocalProgress? local,
  }) {
    return KomgaProgressBase(
      serverPage: server.page,
      serverCompleted: server.completed,
      localValue: local?.value ?? '',
      localUtime: local?.utime ?? '',
    );
  }

  final int? serverPage;
  final bool serverCompleted;
  final String localValue;
  final String localUtime;

  bool serverDiffers(KomgaServerProgress server) =>
      serverPage != server.page || serverCompleted != server.completed;

  bool localDiffers(KomgaLocalProgress? local) =>
      localValue != (local?.value ?? '') || localUtime != (local?.utime ?? '');

  factory KomgaProgressBase.fromJson(Map<String, dynamic> json) {
    return KomgaProgressBase(
      serverPage: (json['serverPage'] as num?)?.toInt(),
      serverCompleted: json['serverCompleted'] as bool? ?? false,
      localValue: json['localValue'] as String? ?? '',
      localUtime: json['localUtime'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'serverPage': serverPage,
    'serverCompleted': serverCompleted,
    'localValue': localValue,
    'localUtime': localUtime,
  };
}

enum KomgaProgressAction { none, pushLocal, applyServer, updateBaseOnly }

/// Clamp a stored local value to the book: invalid or negative values read as
/// unread, indexes past the end read as the last page.
String normalizeKomgaLocalValue(String value, int pageCount) {
  final int? index = int.tryParse(value);
  if (index == null || index < 0) {
    return '';
  }
  return min(index, max(pageCount - 1, 0)).toString();
}

/// Decide how to reconcile one book. Each side is compared with the base
/// rather than with the other side's clock: Komga timestamps come from the
/// server clock with second precision, local ones from the device clock, so
/// timestamps are only compared when both sides changed since the base.
KomgaProgressAction resolveKomgaProgress({
  required KomgaServerProgress server,
  required KomgaLocalProgress? local,
  required KomgaProgressBase? base,
  required int pageCount,
}) {
  final String serverValue = server.toLocalValue(pageCount);
  final String localValue = normalizeKomgaLocalValue(
    local?.value ?? '',
    pageCount,
  );

  if (serverValue == localValue) {
    if (base == null) {
      return localValue.isEmpty
          ? KomgaProgressAction.none
          : KomgaProgressAction.updateBaseOnly;
    }
    return base.serverDiffers(server) || base.localDiffers(local)
        ? KomgaProgressAction.updateBaseOnly
        : KomgaProgressAction.none;
  }

  if (base == null) {
    if (!server.hasProgress) {
      return KomgaProgressAction.pushLocal;
    }
    if (localValue.isEmpty) {
      return KomgaProgressAction.applyServer;
    }
    return _newer(server, local);
  }

  final bool serverChanged = base.serverDiffers(server);
  final bool localChanged = base.localDiffers(local);
  if (!serverChanged && !localChanged) {
    return KomgaProgressAction.none;
  }
  if (!serverChanged) {
    return KomgaProgressAction.pushLocal;
  }
  if (!localChanged) {
    return KomgaProgressAction.applyServer;
  }
  if (!server.hasProgress) {
    // An unread server state carries no timestamp; the local reading wins.
    return KomgaProgressAction.pushLocal;
  }
  return _newer(server, local);
}

/// Newer side wins; a tie goes to the server. A missing server date loses,
/// a missing local record loses.
KomgaProgressAction _newer(
  KomgaServerProgress server,
  KomgaLocalProgress? local,
) {
  final DateTime? localTime = local?.time;
  if (localTime == null) {
    return KomgaProgressAction.applyServer;
  }
  final DateTime? serverTime = server.readDate;
  if (serverTime == null) {
    return KomgaProgressAction.pushLocal;
  }
  return serverTime.isBefore(localTime)
      ? KomgaProgressAction.pushLocal
      : KomgaProgressAction.applyServer;
}
