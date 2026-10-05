/// v7.7.7 or v7.7.7+123. Equal versions are ordered by build number when
/// both sides have one.
int compareVersion(String a, String b) {
  List<String> partsA = a.replaceFirst('v', '').split('+');
  List<String> partsB = b.replaceFirst('v', '').split('+');
  List<String> numberA = partsA[0].split('.');
  List<String> numberB = partsB[0].split('.');

  if (numberA.length != numberB.length) {
    return 0;
  }

  for (int i = 0; i < numberA.length; i++) {
    int a = int.parse(numberA[i]);
    int b = int.parse(numberB[i]);
    if (a > b) {
      return 1;
    } else if (a < b) {
      return -1;
    }
  }

  int? buildA = partsA.length > 1 ? int.tryParse(partsA[1]) : null;
  int? buildB = partsB.length > 1 ? int.tryParse(partsB[1]) : null;
  if (buildA == null || buildB == null) {
    return 0;
  }
  return buildA.compareTo(buildB);
}
