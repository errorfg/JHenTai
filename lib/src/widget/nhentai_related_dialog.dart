import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/service/archive_download_service.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
import 'package:jhentai/src/setting/style_setting.dart';
import 'package:jhentai/src/widget/eh_gallery_list_card_.dart';

class NHentaiRelatedDialog extends StatelessWidget {
  final List<Gallery> gallerys;
  final ValueChanged<Gallery> onTap;

  const NHentaiRelatedDialog({
    super.key,
    required this.gallerys,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('relatedGalleries'.tr),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      content: SizedBox(
        width: 620,
        height: MediaQuery.sizeOf(context).height * 0.65,
        child: ListView.separated(
          itemCount: gallerys.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, index) {
            Gallery gallery = gallerys[index];
            return EHGalleryListCard(
              gallery: gallery,
              downloaded:
                  galleryDownloadService.containGallery(gallery.galleryUrl.storageGid) ||
                  archiveDownloadService.containArchive(gallery.galleryUrl.storageGid),
              listMode: ListMode.listWithoutTags,
              withTags: false,
              handleTapCard: onTap,
            );
          },
        ),
      ),
    );
  }
}
