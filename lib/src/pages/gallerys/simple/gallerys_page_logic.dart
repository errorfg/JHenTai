
import '../../../mixin/home_sync_mixin.dart';
import '../../base/base_page_logic.dart';
import 'gallerys_page_state.dart';

class GallerysPageLogic extends BasePageLogic with HomeSyncLogicMixin {

  @override
  bool get useSearchConfig => true;

  @override
  final GallerysPageState state = GallerysPageState();
}
