import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/service/local_source_favorite_service.dart';

WnacgFavoriteService wnacgFavoriteService = WnacgFavoriteService();

class WnacgFavoriteService extends LocalSourceFavoriteService {
  @override
  ConfigEnum get configEnum => ConfigEnum.wnacgFavorite;

  @override
  bool isSourceGallery(GalleryUrl galleryUrl) => galleryUrl.isWN;

  @override
  String get sourceQualifier => 'wn';
}
