import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';

/// One row of choice chips above a JM list.
class JmChoiceRow<T> extends StatelessWidget {
  const JmChoiceRow({
    super.key,
    required this.choices,
    required this.selected,
    required this.onSelected,
  });

  final List<({T value, String label})> choices;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final ({T value, String label}) choice in choices)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: ChoiceChip(
                label: Text(choice.label),
                selected: choice.value == selected,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => onSelected(choice.value),
              ),
            ),
        ],
      ).enableMouseDrag(withScrollBar: false),
    );
  }
}

/// JM categories as chips; the first chip, all categories, has slug `0`.
class JmCategoryRow extends StatelessWidget {
  const JmCategoryRow({super.key, required this.selected, required this.onSelected});

  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<JmCategories>(
      future: ehRequest.jmSource.categoryList(),
      builder: (_, AsyncSnapshot<JmCategories> snapshot) {
        final List<JmCategory> categories = snapshot.data?.categories ?? const <JmCategory>[];
        return JmChoiceRow<String>(
          choices: [
            (value: '0', label: 'allCategories'.tr),
            for (final JmCategory category in categories)
              if (category.slug.isNotEmpty) (value: category.slug, label: category.name),
          ],
          selected: selected,
          onSelected: onSelected,
        );
      },
    );
  }
}

/// Sort orders of JM lists, see `JmApi.filter`.
List<({String value, String label})> jmOrders({bool ranking = false}) => [
  if (!ranking) (value: 'mr', label: 'jmOrderLatest'.tr),
  (value: 'mv', label: 'jmOrderViews'.tr),
  (value: 'tf', label: 'jmOrderLikes'.tr),
  if (!ranking) (value: 'mp', label: 'jmOrderPages'.tr),
];
