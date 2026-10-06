import 'package:jhentai/src/model/content_scheme.dart';
import '../../../model/search_config.dart';
import '../../../setting/preference_setting.dart';

class NewSearchArgument {
  final String? keyword;
  final SearchBehaviour? keywordSearchBehaviour;

  final SearchConfig? rewriteSearchConfig;

  /// Site a keyword search is for; null leaves it to the current scheme.
  final ContentScheme? site;

  const NewSearchArgument({
    this.keyword,
    this.keywordSearchBehaviour,
    this.rewriteSearchConfig,
    this.site,
  }) : assert((keyword != null && keywordSearchBehaviour != null) || rewriteSearchConfig != null);
}
