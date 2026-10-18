import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/service/local_source_favorite_service.dart';

TachiFavoriteService tachiFavoriteService = TachiFavoriteService();

/// Favorites of Tachiyomi manga, kept on the device and synced like JM's.
/// One entry per manga (its gid), whichever chapter was open.
class TachiFavoriteService extends LocalSourceFavoriteService {
  @override
  ConfigEnum get configEnum => ConfigEnum.tachiFavorite;

  @override
  bool isSourceGallery(GalleryUrl galleryUrl) => galleryUrl.isTachi;

  @override
  String get sourceQualifier => 'tachi';
}
