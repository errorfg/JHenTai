import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../model/gallery_page.dart';
import '../utils/route_util.dart';

class FavoriteSortOrderDialogResult {
  final FavoriteSortOrder sortOrder;
  final bool mixedMode;

  const FavoriteSortOrderDialogResult({
    required this.sortOrder,
    required this.mixedMode,
  });
}

class EHFavoriteSortOrderDialog extends StatefulWidget {
  final FavoriteSortOrder? init;
  final bool initMixedMode;

  const EHFavoriteSortOrderDialog({super.key, this.init, this.initMixedMode = false});

  @override
  State<EHFavoriteSortOrderDialog> createState() => _EHFavoriteSortOrderDialogState();
}

class _EHFavoriteSortOrderDialogState extends State<EHFavoriteSortOrderDialog> {
  FavoriteSortOrder? _sortOrder;
  late bool _mixedMode;

  @override
  void initState() {
    super.initState();
    _sortOrder = widget.init;
    _mixedMode = widget.initMixedMode;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('orderBy'.tr),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RadioListTile(
            title: Text('favoritedTime'.tr),
            value: FavoriteSortOrder.favoritedTime,
            groupValue: _sortOrder,
            onChanged: (value) => setState(() => _sortOrder = value),
          ),
          RadioListTile(
            title: Text('publishedTime'.tr),
            value: FavoriteSortOrder.publishedTime,
            groupValue: _sortOrder,
            onChanged: (value) => setState(() => _sortOrder = value),
          ),
          const Divider(),
          SwitchListTile(
            title: Text('mixNhFavorites'.tr),
            value: _mixedMode,
            onChanged: (value) => setState(() => _mixedMode = value),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: backRoute, child: Text('cancel'.tr)),
        TextButton(
          child: Text('OK'.tr),
          onPressed: () => backRoute(
            result: _sortOrder == null
                ? null
                : FavoriteSortOrderDialogResult(sortOrder: _sortOrder!, mixedMode: _mixedMode),
          ),
        ),
      ],
      actionsPadding: const EdgeInsets.only(left: 24, right: 24, bottom: 12),
    );
  }
}
