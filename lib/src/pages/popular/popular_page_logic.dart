import '../../model/gallery.dart';
import '../base/base_page_logic.dart';
import 'popular_page_state.dart';

class PopularPageLogic extends BasePageLogic {
  @override
  final PopularPageState state = PopularPageState();

  @override
  bool get useSearchConfig => true;

  @override
  Future<List<Gallery>> postHandleNewGallerys(List<Gallery> gallerys, {bool cleanDuplicate = true}) async {
    List<Gallery> processedGallerys = await super.postHandleNewGallerys(gallerys, cleanDuplicate: cleanDuplicate);

    // Apply local filters based on searchConfig
    return _applyLocalFilters(processedGallerys);
  }

  List<Gallery> _applyLocalFilters(List<Gallery> gallerys) {
    return gallerys.where((gallery) {
      // Category filter
      if (!_matchesCategory(gallery.category)) {
        return false;
      }

      // Page range filter
      if (gallery.pageCount != null) {
        if (state.searchConfig.pageAtLeast != null && gallery.pageCount! < state.searchConfig.pageAtLeast!) {
          return false;
        }
        if (state.searchConfig.pageAtMost != null && gallery.pageCount! > state.searchConfig.pageAtMost!) {
          return false;
        }
      }

      // Minimum rating filter
      if (gallery.rating < state.searchConfig.minimumRating) {
        return false;
      }

      // Language filter
      if (state.searchConfig.language != null &&
          gallery.language != null &&
          !gallery.language!.toLowerCase().contains(state.searchConfig.language!.toLowerCase())) {
        return false;
      }

      // Expunged galleries filter
      if (state.searchConfig.onlySearchExpungedGalleries && !gallery.isExpunged) {
        return false;
      }
      if (!state.searchConfig.onlySearchExpungedGalleries && gallery.isExpunged) {
        return false;
      }

      // Keyword filter (search in title)
      if (state.searchConfig.keyword != null && state.searchConfig.keyword!.isNotEmpty) {
        if (!gallery.title.toLowerCase().contains(state.searchConfig.keyword!.toLowerCase())) {
          return false;
        }
      }

      // Tag filter
      if (state.searchConfig.tags != null && state.searchConfig.tags!.isNotEmpty) {
        if (!_matchesTags(gallery)) {
          return false;
        }
      }

      return true;
    }).toList();
  }

  bool _matchesCategory(String category) {
    switch (category.toLowerCase()) {
      case 'doujinshi':
        return state.searchConfig.includeDoujinshi;
      case 'manga':
        return state.searchConfig.includeManga;
      case 'artist cg':
        return state.searchConfig.includeArtistCG;
      case 'game cg':
        return state.searchConfig.includeGameCg;
      case 'western':
        return state.searchConfig.includeWestern;
      case 'non-h':
        return state.searchConfig.includeNonH;
      case 'image set':
        return state.searchConfig.includeImageSet;
      case 'cosplay':
        return state.searchConfig.includeCosplay;
      case 'asian porn':
        return state.searchConfig.includeAsianPorn;
      case 'misc':
        return state.searchConfig.includeMisc;
      default:
        return true;
    }
  }

  bool _matchesTags(Gallery gallery) {
    for (var searchTag in state.searchConfig.tags!) {
      bool found = false;

      // Check if the namespace exists in gallery tags
      if (searchTag.namespace.isEmpty) {
        // Manual input without namespace, search in all tags
        for (var tagList in gallery.tags.values) {
          if (tagList.any((tag) => tag.tagData.key.toLowerCase().contains(searchTag.key.toLowerCase()))) {
            found = true;
            break;
          }
        }
      } else {
        // Search in specific namespace
        var tagList = gallery.tags[searchTag.namespace];
        if (tagList != null) {
          found = tagList.any((tag) => tag.tagData.key.toLowerCase() == searchTag.key.toLowerCase());
        }
      }

      // All tags must match (AND logic)
      if (!found) {
        return false;
      }
    }

    return true;
  }
}
