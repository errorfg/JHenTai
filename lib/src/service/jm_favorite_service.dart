import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/service/local_source_favorite_service.dart';

JmFavoriteService jmFavoriteService = JmFavoriteService();

class JmFavoriteService extends LocalSourceFavoriteService {
  @override
  ConfigEnum get configEnum => ConfigEnum.jmFavorite;

  @override
  bool isSourceGallery(GalleryUrl galleryUrl) => galleryUrl.isJM;

  @override
  String get sourceQualifier => 'jm';
}
