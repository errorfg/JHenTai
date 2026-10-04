import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/pages/read/read_page_logic.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

ItemPosition _item(int index, double leading, double trailing) => ItemPosition(
  index: index,
  itemLeadingEdge: leading,
  itemTrailingEdge: trailing,
);

void main() {
  group('scrolling layouts', () {
    test('the end is reached once the last page is shown to its end', () {
      expect(
        listShowsEnd([_item(18, -0.3, 0.4), _item(19, 0.4, 1.0)], 20),
        isTrue,
      );
    });

    test('a partly visible last page is not the end', () {
      expect(
        listShowsEnd([_item(18, -0.1, 0.6), _item(19, 0.6, 1.3)], 20),
        isFalse,
      );
    });

    test('a tall last page counts only when scrolled to its bottom', () {
      expect(listShowsEnd([_item(19, -2.0, 1.4)], 20), isFalse);
      expect(listShowsEnd([_item(19, -2.4, 1.0)], 20), isTrue);
    });

    test('earlier pages never count', () {
      expect(listShowsEnd([_item(17, 0, 0.5), _item(18, 0.5, 1)], 20), isFalse);
    });
  });

  group('persisted progress index', () {
    test('records the last page once the end is reached', () {
      expect(
        progressIndexFor(currentIndex: 18, reachedEnd: true, pageCount: 20),
        19,
      );
    });

    test('records the first visible image otherwise, including after leaving '
        'the end', () {
      expect(
        progressIndexFor(currentIndex: 18, reachedEnd: false, pageCount: 20),
        18,
      );
    });
  });
}
