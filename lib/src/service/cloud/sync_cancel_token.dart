/// Tells a sync that has been given up to stop. The sync looks before each
/// step that writes (into this device's data or to the remote) and ends
/// there with [SyncCancelledException]; a step already under way finishes.
class SyncCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) {
      throw const SyncCancelledException();
    }
  }
}

class SyncCancelledException implements Exception {
  const SyncCancelledException();

  @override
  String toString() => 'The sync was given up';
}
