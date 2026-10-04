import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/komga/komga_query.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/pages/komga/komga_browse_controller.dart';

/// Pick filter values. Only categories the server has values for are shown;
/// book lists offer authors and tags (Komga's book conditions have no
/// publisher, language or genre). Returns null when dismissed.
Future<KomgaFilters?> showKomgaFilterSheet(
  BuildContext context, {
  required KomgaBrowseController controller,
  required String? libraryId,
  required KomgaTarget target,
  required KomgaFilters initial,
}) {
  return showModalBottomSheet<KomgaFilters>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext context) => _KomgaFilterSheet(
      controller: controller,
      libraryId: libraryId,
      target: target,
      initial: initial,
    ),
  );
}

class _KomgaFilterSheet extends StatefulWidget {
  const _KomgaFilterSheet({
    required this.controller,
    required this.libraryId,
    required this.target,
    required this.initial,
  });

  final KomgaBrowseController controller;
  final String? libraryId;
  final KomgaTarget target;
  final KomgaFilters initial;

  @override
  State<_KomgaFilterSheet> createState() => _KomgaFilterSheetState();
}

class _KomgaFilterSheetState extends State<_KomgaFilterSheet> {
  late KomgaFilters _filters = widget.initial;
  late final Future<KomgaFilterOptions> _options = widget.controller
      .filterOptions(widget.libraryId);

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (BuildContext context, ScrollController scroll) {
        return FutureBuilder<KomgaFilterOptions>(
          future: _options,
          builder: (BuildContext context, AsyncSnapshot<KomgaFilterOptions> snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text(KomgaClient.friendlyError(snapshot.error!)));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final KomgaFilterOptions options = snapshot.data!;
            final bool series = widget.target == KomgaTarget.series;
            final List<Widget> sections = <Widget?>[
              _section('komgaAuthors'.tr, options.authors, _filters.authors,
                  (Set<String> v) => _filters.copyWith(authors: v)),
              if (series)
                _section('komgaPublishers'.tr, options.publishers, _filters.publishers,
                    (Set<String> v) => _filters.copyWith(publishers: v)),
              if (series)
                _section('komgaLanguages'.tr, options.languages, _filters.languages,
                    (Set<String> v) => _filters.copyWith(languages: v)),
              if (series)
                _section('komgaGenres'.tr, options.genres, _filters.genres,
                    (Set<String> v) => _filters.copyWith(genres: v)),
              _section('komgaTags'.tr, options.tags, _filters.tags,
                  (Set<String> v) => _filters.copyWith(tags: v)),
            ].whereType<Widget>().toList();
            return Column(
              children: <Widget>[
                Expanded(
                  child: sections.isEmpty
                      ? Center(child: Text('komgaNoFilterValues'.tr))
                      : ListView(
                          controller: scroll,
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          children: sections,
                        ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Row(
                      children: <Widget>[
                        TextButton(
                          onPressed: () => setState(() => _filters = const KomgaFilters()),
                          child: Text('komgaClearFilters'.tr),
                        ),
                        const Spacer(),
                        FilledButton(
                          key: const ValueKey<String>('komgaApplyFilters'),
                          onPressed: () => Navigator.of(context).pop(_filters),
                          child: Text('komgaApplyFilters'.tr),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget? _section(
    String title,
    List<String> values,
    Set<String> selected,
    KomgaFilters Function(Set<String>) update,
  ) {
    if (values.isEmpty) {
      return null;
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final String value in values)
                FilterChip(
                  label: Text(value),
                  selected: selected.contains(value),
                  onSelected: (bool on) => setState(() {
                    final Set<String> next = <String>{...selected};
                    on ? next.add(value) : next.remove(value);
                    _filters = update(next);
                  }),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
