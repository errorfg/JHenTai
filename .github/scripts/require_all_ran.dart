// Fails when a test in a JSON test report (flutter test --file-reporter
// json:<path>) was skipped, or when none ran. The tests CI runs need nothing
// beyond what the workflow sets up; those that need real accounts, sites or
// tools are tagged `external` and left out (see dart_test.yaml). A skip
// here means something a test needs is missing.
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final Map<int, String> names = <int, String>{};
  final List<String> skipped = <String>[];
  int ran = 0;
  for (final String line in File(args.single).readAsLinesSync()) {
    if (!line.startsWith('{')) {
      continue;
    }
    final Map<String, dynamic> event = jsonDecode(line) as Map<String, dynamic>;
    if (event['type'] == 'testStart') {
      final Map<String, dynamic> test = event['test'] as Map<String, dynamic>;
      names[test['id'] as int] = test['name'] as String;
    } else if (event['type'] == 'testDone' && event['hidden'] != true) {
      if (event['skipped'] == true) {
        skipped.add(names[event['testID'] as int] ?? '#${event['testID']}');
      } else {
        ran++;
      }
    }
  }
  if (skipped.isNotEmpty || ran == 0) {
    stderr.writeln('$ran tests ran; ${skipped.length} skipped that must run:');
    for (final String name in skipped) {
      stderr.writeln('  $name');
    }
    exit(1);
  }
  stdout.writeln('$ran tests ran, none skipped');
}
