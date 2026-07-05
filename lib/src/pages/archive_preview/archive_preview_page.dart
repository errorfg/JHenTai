import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/read_page_info.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/archive_download_service.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/super_resolution_service.dart';
import 'package:jhentai/src/setting/read_setting.dart';
import 'package:jhentai/src/utils/byte_util.dart';
import 'package:jhentai/src/utils/process_util.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/widget/eh_image.dart';
import 'package:jhentai/src/widget/eh_wheel_speed_controller.dart';
import 'package:jhentai/src/widget/icon_text_button.dart';

class ArchivePreviewPage extends StatefulWidget {
  const ArchivePreviewPage({super.key});

  @override
  State<ArchivePreviewPage> createState() => _ArchivePreviewPageState();
}

class _ArchivePreviewPageState extends State<ArchivePreviewPage> {
  final ScrollController scrollController = ScrollController();
  late final int? gid = _parseGid(Get.arguments);
  late final ArchiveDownloadedData? archive = gid == null
      ? null
      : archiveDownloadService.archives
          .firstWhereOrNull((archive) => archive.gid == gid);
  late Future<List<GalleryImage>> imagesFuture;

  @override
  void initState() {
    super.initState();
    imagesFuture = archive == null
        ? Future.value([])
        : archiveDownloadService.getUnpackedImages(archive!.gid);
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  int? _parseGid(Object? arguments) {
    if (arguments is int) {
      return arguments;
    }
    if (arguments is ArchiveDownloadedData) {
      return arguments.gid;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (archive == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('failed'.tr)),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          archive!.title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
      ),
      body: EHWheelSpeedController(
        controller: scrollController,
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics()),
          scrollBehavior: UIConfig.scrollBehaviourWithScrollBarWithMouse,
          controller: scrollController,
          cacheExtent: 5000,
          slivers: [
            CupertinoSliverRefreshControl(onRefresh: _refreshImages),
            _buildDetail(context),
            _buildActions(context),
            _buildDivider(context),
            _buildThumbnails(),
          ],
        ),
      ),
    );
  }

  Future<void> _refreshImages() async {
    if (archive == null) {
      return;
    }
    await archiveDownloadService.rebuildUnpackedImageIndex(archive!.gid);
    setState(() {
      imagesFuture = archiveDownloadService.getUnpackedImages(archive!.gid);
    });
  }

  Widget _buildDetail(BuildContext context) {
    return SliverToBoxAdapter(
      child: LayoutBuilder(
        builder: (context, constraints) {
          bool narrow = constraints.maxWidth < 520;
          Widget cover = _buildCover(context);
          Widget info = _buildInfo(context);

          return Container(
            margin: const EdgeInsets.only(
              top: 12,
              left: UIConfig.detailPagePadding,
              right: UIConfig.detailPagePadding,
            ),
            child: narrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(child: cover),
                      const SizedBox(height: 14),
                      info,
                    ],
                  )
                : SizedBox(
                    height: UIConfig.detailsPageHeaderHeight,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        cover,
                        const SizedBox(width: 10),
                        Expanded(child: info),
                      ],
                    ),
                  ),
          );
        },
      ),
    );
  }

  Widget _buildCover(BuildContext context) {
    GalleryImage cover =
        archiveDownloadService.buildArchiveCoverImage(archive!);
    return GestureDetector(
      onTap: () => _goToReadPage(initialIndex: 0),
      child: EHImage(
        galleryImage: cover,
        containerHeight: UIConfig.detailsPageCoverHeight,
        containerWidth: UIConfig.detailsPageCoverWidth,
        borderRadius:
            BorderRadius.circular(UIConfig.detailsPageCoverBorderRadius),
        heroTag: cover,
        shadows: [
          BoxShadow(
            color: UIConfig.detailPageCoverShadowColor(context),
            blurRadius: 5,
            offset: const Offset(3, 5),
          ),
        ],
        maxBytes: 512 * 1024,
      ),
    );
  }

  Widget _buildInfo(BuildContext context) {
    ArchiveDownloadInfo? info =
        archiveDownloadService.archiveDownloadInfos[archive!.gid];
    TextStyle labelStyle = TextStyle(
      color: Theme.of(context).colorScheme.outline,
      fontSize: 12,
    );
    TextStyle valueStyle = const TextStyle(fontSize: 13);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          archive!.title,
          minLines: 1,
          maxLines: 5,
          style: const TextStyle(
            fontSize: UIConfig.detailsPageTitleTextSize,
            letterSpacing: UIConfig.detailsPageTitleLetterSpacing,
            height: UIConfig.detailsPageTitleTextHeight,
          ),
        ),
        const SizedBox(height: 12),
        _buildInfoRow('pageCount'.tr, archive!.pageCount.toString(), labelStyle,
            valueStyle),
        _buildInfoRow('size'.tr, byte2String(archive!.size.toDouble()),
            labelStyle, valueStyle),
        _buildInfoRow('group'.tr, info?.group ?? archive!.groupName, labelStyle,
            valueStyle),
        _buildInfoRow('category'.tr, archive!.category, labelStyle, valueStyle),
        _buildInfoRow(
            'publishTime'.tr, archive!.insertTime, labelStyle, valueStyle),
      ],
    );
  }

  Widget _buildInfoRow(
      String label, String value, TextStyle labelStyle, TextStyle valueStyle) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 90, child: Text(label, style: labelStyle)),
          Expanded(child: SelectableText(value, style: valueStyle)),
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        height: UIConfig.detailsPageActionsHeight,
        margin: const EdgeInsets.only(
          top: 16,
          left: UIConfig.detailPagePadding,
          right: UIConfig.detailPagePadding,
        ),
        child: IconTextButton(
          width: UIConfig.detailsPageActionExtent,
          icon: Icon(
            Icons.visibility,
            color: UIConfig.detailsPageActionIconColor(context),
          ),
          text: Text(
            'read'.tr,
            style: TextStyle(
              fontSize: UIConfig.detailsPageActionTextSize,
              color: UIConfig.detailsPageActionTextColor(context),
              height: 1,
            ),
          ),
          onPressed: _goToReadPage,
        ),
      ),
    );
  }

  Widget _buildDivider(BuildContext context) {
    return SliverToBoxAdapter(
      child: Divider(
        height: 36,
        indent: UIConfig.detailPagePadding,
        endIndent: UIConfig.detailPagePadding,
        color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
      ),
    );
  }

  Widget _buildThumbnails() {
    return FutureBuilder<List<GalleryImage>>(
      future: imagesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return SliverToBoxAdapter(
            child: SizedBox(
              height: 160,
              child: Center(child: UIConfig.loadingAnimation(context)),
            ),
          );
        }

        List<GalleryImage> images = snapshot.data ?? [];
        if (images.isEmpty) {
          return SliverToBoxAdapter(
            child: SizedBox(
              height: 160,
              child: Center(child: Text('failed'.tr)),
            ),
          );
        }

        return SliverPadding(
          padding: const EdgeInsets.only(
            left: UIConfig.detailPagePadding,
            right: UIConfig.detailPagePadding,
            bottom: 24,
          ),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 112,
              mainAxisSpacing: 14,
              crossAxisSpacing: 10,
              childAspectRatio: 0.62,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) => Column(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () =>
                          _goToReadPage(initialIndex: index, images: images),
                      child: EHImage(
                        galleryImage: images[index],
                        autoLayout: true,
                        borderRadius: BorderRadius.circular(8),
                        fit: BoxFit.cover,
                        maxBytes: 160 * 1024,
                        clearMemoryCacheWhenDispose: true,
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    (index + 1).toString(),
                    style: TextStyle(
                      color: UIConfig.detailsPageThumbnailIndexColor(context),
                    ),
                  ),
                ],
              ),
              childCount: images.length,
            ),
          ),
        );
      },
    );
  }

  Future<void> _goToReadPage(
      {int? initialIndex, List<GalleryImage>? images}) async {
    if (archive == null ||
        archiveDownloadService
                .archiveDownloadInfos[archive!.gid]?.archiveStatus !=
            ArchiveStatus.completed) {
      return;
    }

    if (readSetting.useThirdPartyViewer.isTrue &&
        readSetting.thirdPartyViewerPath.value != null) {
      openThirdPartyViewer(archiveDownloadService.computeArchiveUnpackingPath(
          archive!.title, archive!.gid));
      return;
    }

    images ??= await archiveDownloadService.getUnpackedImages(archive!.gid);
    int readIndexRecord =
        initialIndex ?? await readProgressService.getReadProgress(archive!.gid);

    toRoute(
      Routes.read,
      arguments: ReadPageInfo(
        mode: ReadMode.archive,
        gid: archive!.gid,
        galleryTitle: archive!.title,
        galleryUrl: archive!.galleryUrl,
        initialIndex: readIndexRecord,
        pageCount: images.length,
        isOriginal: archive!.isOriginal,
        readProgressRecordStorageKey: archive!.gid.toString(),
        images: images,
        useSuperResolution: superResolutionService.get(
                archive!.gid, SuperResolutionType.archive) !=
            null,
      ),
    );
  }
}
