import '../../../routes/routes.dart';
import '../../base/base_page_state.dart';

class GallerysPageState extends BasePageState {
  bool syncInProgress = false;
  double syncProgress = 0;

  @override
  String get route => Routes.gallerys;
}
