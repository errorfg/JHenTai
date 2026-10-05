import 'package:path/path.dart' as path;

/// Pure path-computation helpers for download storage. Only the archive
/// restore helpers are used here so far.
class DownloadPathResolver {
  static const int legacyArchiveTitleMaxChars = 80;

  /// Reproduce the pre-sanitizedTitle archive unpacking-directory naming rule.
  ///
  /// Old releases sanitized illegal characters and then truncated the title to
  /// 80 Dart string characters. Metadata written by those releases has no
  /// `sanitizedTitle`, so using the current byte-based rule while restoring it
  /// can point every image at an unpacking directory that never existed on disk.
  static String computeLegacyArchiveTitle(String rawTitle) {
    String title = rawTitle.replaceAll(RegExp(r'[/|?,:*"<>\\.]'), ' ').trim();
    if (title.length > legacyArchiveTitleMaxChars) {
      title = title.substring(0, legacyArchiveTitleMaxChars).trim();
    }
    return title;
  }

  /// Resolve the archive unpacking-directory title to use while restoring
  /// metadata from disk, for the `Archive - {gid} - {title}` directory shape:
  /// prefer the scanned directory's own suffix (that is where the unpacked
  /// image bytes live), then the persisted value, and finally the legacy
  /// 80-char rule for metadata written before `sanitizedTitle` existed.
  static String resolveArchiveSanitizedTitleForRestore({
    required int gid,
    required String rawTitle,
    required String? persistedSanitizedTitle,
    required String archiveDirectoryPath,
  }) {
    final String directoryName = path.basename(path.normalize(archiveDirectoryPath));
    final String prefix = 'Archive - $gid - ';
    if (directoryName.startsWith(prefix)) {
      return directoryName.substring(prefix.length);
    }
    return persistedSanitizedTitle ?? computeLegacyArchiveTitle(rawTitle);
  }
}
