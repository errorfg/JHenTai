import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/read_page_info.dart';
import 'package:jhentai/src/model/reader_source.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/pdf_service.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:jhentai/src/widget/eh_image.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';
import 'package:jhentai/src/widget/reader_source_switcher.dart';

class PdfLibraryPage extends StatefulWidget {
  const PdfLibraryPage({super.key});

  @override
  State<PdfLibraryPage> createState() => _PdfLibraryPageState();
}

class _PdfLibraryPageState extends State<PdfLibraryPage> {
  String? _openingPath;

  @override
  void initState() {
    super.initState();
    if (!Get.isRegistered<PdfService>()) {
      Get.put<PdfService>(pdfService, permanent: true);
    }
    pdfService.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const ReaderSourceDrawer(currentSource: ReaderSourceType.pdf),
      appBar: AppBar(
        title: Text('pdfLibrary'.tr),
        actions: [
          IconButton(
            tooltip: 'refresh'.tr,
            onPressed: pdfService.loadingState == LoadingState.loading
                ? null
                : pdfService.refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: GetBuilder<PdfService>(
        init: pdfService,
        builder: (_) => _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (pdfService.loadingState == LoadingState.loading &&
        pdfService.documents.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (pdfService.loadingState == LoadingState.error) {
      return Center(
        child: FilledButton.icon(
          onPressed: pdfService.refresh,
          icon: const Icon(Icons.refresh),
          label: Text('retry'.tr),
        ),
      );
    }
    if (pdfService.documents.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.picture_as_pdf_outlined, size: 64),
              const SizedBox(height: 18),
              Text(
                'pdfLibraryEmpty'.tr,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 17),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: pdfService.refresh,
      child: GridView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 210,
          childAspectRatio: 0.59,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: pdfService.documents.length,
        itemBuilder: (_, int index) =>
            _buildPdfCard(context, pdfService.documents[index]),
      ),
    );
  }

  Widget _buildPdfCard(BuildContext context, PdfDocumentEntry entry) {
    final bool isOpening = _openingPath == entry.path;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: isOpening ? null : () => _openDocument(entry),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  EHImage(galleryImage: entry.cover, fit: BoxFit.cover),
                  if (isOpening)
                    const ColoredBox(
                      color: Colors.black45,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                ],
              ),
            ),
            FutureBuilder<int>(
              future: readProgressService.getReadProgressByKey(
                entry.progressKey,
              ),
              builder: (_, AsyncSnapshot<int> snapshot) {
                final int index = snapshot.data ?? 0;
                final double progress = entry.pageCount <= 0
                    ? 0
                    : ((index + 1) / entry.pageCount).clamp(0, 1).toDouble();
                return LinearProgressIndicator(
                  value: progress == 0 ? null : progress,
                  minHeight: 3,
                  backgroundColor: Colors.transparent,
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 3),
              child: Text(
                entry.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 9),
              child: Text(
                '${entry.pageCount}P',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openDocument(PdfDocumentEntry entry) async {
    setState(() => _openingPath = entry.path);
    try {
      final images = await pdfService.getDocumentImages(entry);
      if (images.isEmpty) {
        throw StateError('pdfHasNoPages'.tr);
      }
      final int savedIndex = await readProgressService.getReadProgressByKey(
        entry.progressKey,
      );
      final int initialIndex = min(max(savedIndex, 0), images.length - 1);

      await toRoute<dynamic>(
        Routes.read,
        arguments: ReadPageInfo(
          mode: ReadMode.local,
          galleryTitle: entry.title,
          initialIndex: initialIndex,
          pageCount: images.length,
          readProgressRecordStorageKey: entry.progressKey,
          images: images,
          useSuperResolution: false,
        ),
      );
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      toast(e.toString(), isShort: false);
    } finally {
      if (mounted) {
        setState(() => _openingPath = null);
      }
    }
  }
}
