import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/service/series_reading_service.dart';

export 'package:jhentai/src/service/series_reading_service.dart';

JmReadingService jmReadingService = JmReadingService();

typedef JmChapterProgress = SeriesChapterProgress;

typedef JmAlbumProgress = SeriesProgress;

/// Reading state of multi-chapter JM albums; see [SeriesReadingService] for
/// what is kept. The keys are `jm:pages:`, `jm:album:` and `jm:chapters:`.
class JmReadingService extends SeriesReadingService {
  JmReadingService() : super(prefix: 'jm', gidOf: (int chapterId) => GalleryUrl.jm(chapterId).gid);

  static const String markedReadValue = SeriesReadingService.markedReadValue;

  static String chapterKey(int chapterId) => GalleryUrl.jm(chapterId).gid.toString();

  static String pagesKey(int chapterId) => 'jm:pages:$chapterId';

  static String albumKey(int albumId) => 'jm:album:$albumId';

  static String chaptersKey(int albumId) => 'jm:chapters:$albumId';

  static int resumeChapter(List<int> chapterIds, Map<int, SeriesChapterProgress> progress) =>
      SeriesReadingService.resumeChapter(chapterIds, progress);
}
