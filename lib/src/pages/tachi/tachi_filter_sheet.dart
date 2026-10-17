import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/network/tachi/tachi_models.dart';

/// The filters of a Tachiyomi source, as the source declares them. Edits a
/// copy; closes with the edited filters on apply, with null when dismissed.
/// [onReset] gives the source's own defaults.
class TachiFilterSheet extends StatefulWidget {
  const TachiFilterSheet({super.key, required this.filters, required this.onReset});

  final List<TachiFilter> filters;
  final Future<List<TachiFilter>> Function() onReset;

  /// Shows the sheet; the filters chosen, or null.
  static Future<List<TachiFilter>?> show(BuildContext context, {required List<TachiFilter> filters, required Future<List<TachiFilter>> Function() onReset}) {
    return showModalBottomSheet<List<TachiFilter>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => TachiFilterSheet(filters: filters, onReset: onReset),
    );
  }

  @override
  State<TachiFilterSheet> createState() => _TachiFilterSheetState();
}

class _TachiFilterSheetState extends State<TachiFilterSheet> {
  late List<TachiFilter> _filters = _copy(widget.filters);

  static List<TachiFilter> _copy(List<TachiFilter> filters) => TachiFilter.listFromJson(jsonDecode(jsonEncode(TachiFilter.listToJson(filters))) as List);

  Future<void> _reset() async {
    final List<TachiFilter> defaults = await widget.onReset();
    if (mounted) {
      setState(() => _filters = _copy(defaults));
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (BuildContext context, ScrollController controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: Row(
              children: [
                Text('filter'.tr, style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton(onPressed: _reset, child: Text('reset'.tr)),
                FilledButton(onPressed: () => Navigator.of(context).pop(_filters), child: Text('tachiApply'.tr)),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.only(bottom: 24),
              children: [for (final TachiFilter filter in _filters) _buildFilter(context, filter)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilter(BuildContext context, TachiFilter filter) {
    switch (filter.type) {
      case 'header':
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(filter.name, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
        );
      case 'separator':
        return const Divider(indent: 16, endIndent: 16);
      case 'select':
        final List<String> values = filter.values;
        final int selected = (filter.state as num?)?.toInt() ?? 0;
        return ListTile(
          title: Text(filter.name),
          trailing: DropdownButton<int>(
            value: selected.clamp(0, values.isEmpty ? 0 : values.length - 1),
            items: [for (int i = 0; i < values.length; i++) DropdownMenuItem<int>(value: i, child: Text(values[i], overflow: TextOverflow.ellipsis))],
            onChanged: (int? v) => setState(() => filter.state = v ?? 0),
          ),
        );
      case 'text':
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: TextFormField(
            initialValue: filter.state as String? ?? '',
            decoration: InputDecoration(labelText: filter.name, isDense: true),
            onChanged: (String v) => filter.state = v,
          ),
        );
      case 'checkbox':
        return CheckboxListTile(
          dense: true,
          title: Text(filter.name),
          value: filter.state as bool? ?? false,
          onChanged: (bool? v) => setState(() => filter.state = v ?? false),
        );
      case 'tristate':
        // 0 ignore, 1 include, 2 exclude.
        final int state = (filter.state as num?)?.toInt() ?? 0;
        return ListTile(
          dense: true,
          title: Text(filter.name),
          leading: Icon(
            state == 1 ? Icons.check_box : (state == 2 ? Icons.indeterminate_check_box : Icons.check_box_outline_blank),
            color: state == 2 ? Theme.of(context).colorScheme.error : (state == 1 ? Theme.of(context).colorScheme.primary : null),
          ),
          onTap: () => setState(() => filter.state = (state + 1) % 3),
        );
      case 'sort':
        final Map<String, dynamic>? selection = filter.state as Map<String, dynamic>?;
        final int? index = (selection?['index'] as num?)?.toInt();
        final bool ascending = selection?['ascending'] as bool? ?? false;
        final List<String> values = filter.values;
        return ExpansionTile(
          title: Text(filter.name),
          subtitle: index == null || index >= values.length ? null : Text(values[index]),
          children: [
            for (int i = 0; i < values.length; i++)
              ListTile(
                dense: true,
                title: Text(values[i]),
                leading: Icon(i == index ? (ascending ? Icons.arrow_upward : Icons.arrow_downward) : null),
                onTap: () => setState(() => filter.state = <String, dynamic>{'index': i, 'ascending': i == index ? !ascending : false}),
              ),
          ],
        );
      case 'group':
        return ExpansionTile(
          title: Text(filter.name),
          children: [for (final TachiFilter child in filter.children) _buildFilter(context, child)],
        );
      default:
        return const SizedBox();
    }
  }
}
