import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' as drift show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/l18n/locale_text.dart';
import 'package:jhentai/src/model/komga/komga_browse_models.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/pages/komga/komga_page.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/komga_setting.dart';

class _FakeKomgaClient extends KomgaClient {
  _FakeKomgaClient()
    : super(
        serverUrl: 'https://komga.test',
        username: 'reader',
        password: 'secret',
        apiKey: '',
        connectionId: 'fixture-connection',
      );

  int allSeriesCalls = 0;
  int allBooksCalls = 0;
  int librariesCalls = 0;
  int readProgressBooksCalls = 0;
  Completer<List<KomgaBook>>? allBooksCompleter;
  Completer<List<KomgaBook>>? readProgressBooksCompleter;
  List<KomgaBook> readProgressBooks = <KomgaBook>[];
  final List<KomgaBook> books = <KomgaBook>[
    _book('book-1', 'Zulu Continue', DateTime.utc(2026, 8, 1)),
    _book('book-2', 'Alpha Unread', DateTime.utc(2026, 7, 30)),
    _book('book-3', 'Bravo Read', DateTime.utc(2026, 7, 31)),
    _book('book-4', 'Charlie New', DateTime.utc(2026, 8, 3)),
  ];

  @override
  Future<List<KomgaLibrary>> getLibraries() async {
    librariesCalls++;
    return const <KomgaLibrary>[KomgaLibrary(id: 'library-1', name: 'Manga')];
  }

  @override
  Future<List<KomgaSeries>> getAllSeries({
    required String libraryId,
    bool descending = true,
  }) async {
    allSeriesCalls++;
    return <KomgaSeries>[_series()];
  }

  @override
  Future<List<KomgaBook>> getAllBooks({
    required String libraryId,
    bool descending = true,
  }) async {
    allBooksCalls++;
    return List<KomgaBook>.of(
      allBooksCompleter == null ? books : await allBooksCompleter!.future,
    );
  }

  @override
  Future<List<KomgaBook>> getAllReadProgressBooks() async {
    readProgressBooksCalls++;
    return List<KomgaBook>.of(
      readProgressBooksCompleter == null
          ? readProgressBooks
          : await readProgressBooksCompleter!.future,
    );
  }

  @override
  String seriesThumbnailUrl(String seriesId) {
    return 'https://komga.test/series-thumbnail/$seriesId';
  }

  @override
  String bookThumbnailUrl(String bookId) {
    return 'https://komga.test/book-thumbnail/$bookId';
  }
}

class _FakeSyncService extends SyncService {
  int readProgressSyncCalls = 0;
  final List<({bool requireAutoSync, bool force})> requests = [];
  SyncResult? result = SyncResult(
    success: true,
    message: 'ok',
    statistics: const {},
  );

  @override
  Future<SyncResult?> syncReadProgress({
    bool requireAutoSync = true,
    bool force = false,
  }) async {
    readProgressSyncCalls++;
    requests.add((requireAutoSync: requireAutoSync, force: force));
    return result;
  }
}

class _SilentLogService extends LogService {
  @override
  void trace(Object msg, [bool withStack = false]) {}
  @override
  void debug(Object msg, [bool withStack = false]) {}
  @override
  void info(Object msg, [bool withStack = false]) {}
  @override
  void warning(Object msg, [Object? error, bool withStack = false]) {}
  @override
  void error(Object msg, [Object? error, StackTrace? stackTrace]) {}
}

void main() {
  late AppDb originalDb;
  late KomgaSetting originalKomgaSetting;
  late ReadProgressService originalReadProgressService;
  late SyncService originalSyncService;
  late LogService originalLog;
  late _FakeSyncService fakeSyncService;

  setUp(() async {
    originalDb = appDb;
    originalKomgaSetting = komgaSetting;
    originalReadProgressService = readProgressService;
    originalSyncService = syncService;
    originalLog = log;
    log = _SilentLogService();
    appDb = AppDb.forTesting(NativeDatabase.memory());
    komgaSetting = KomgaSetting()
      ..applyBeanConfig(
        jsonEncode(<String, dynamic>{
          'serverUrl': 'https://komga.test',
          'username': 'reader',
          'password': 'secret',
          'apiKey': '',
          'connectionId': 'fixture-connection',
        }),
      );
    readProgressService = ReadProgressService();
    fakeSyncService = _FakeSyncService();
    syncService = fakeSyncService;
    await localConfigService.batchWrite(<LocalConfigCompanion>[
      _progressRow(
        'komga:fixture-connection:book-1',
        '0',
        '2026-08-04T10:00:00.000000Z',
      ),
      _progressRow(
        'komga:fixture-connection:book-3',
        '9',
        '2026-08-03T09:00:00.000000Z',
      ),
    ]);
    await localConfigService.write(
      configKey: ConfigEnum.komgaBrowseSetting,
      value: jsonEncode(<String, dynamic>{
        'libraryView': 'series',
        'displayMode': 'grid',
        'progressFilter': 'all',
        'sortMode': 'addedAt',
        'descending': true,
        'lastSeenByLibrary': <String, String>{
          'fixture-connection::library-1': '2026-08-02T00:00:00.000Z',
        },
      }),
    );
  });

  tearDown(() async {
    await appDb.close();
    appDb = originalDb;
    komgaSetting = originalKomgaSetting;
    readProgressService = originalReadProgressService;
    syncService = originalSyncService;
    log = originalLog;
    Get.reset();
  });

  testWidgets(
    'series/books, progress filters, and three display modes share one load',
    (WidgetTester tester) async {
      final _FakeKomgaClient client = _FakeKomgaClient();
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        GetMaterialApp(
          translations: LocaleText(),
          locale: const Locale('zh', 'CN'),
          home: KomgaPage(clientFactory: () => client),
        ),
      );
      await _pumpFrames(tester);

      expect(
        tester
            .widgetList<Text>(find.byType(Text))
            .map((Text widget) => widget.data),
        contains('Manga'),
      );
      await tester.tap(find.text('Manga'));
      await _pumpFrames(tester);

      expect(client.allSeriesCalls, 1);
      expect(client.allBooksCalls, 1);
      expect(find.text('系列'), findsOneWidget);
      expect(find.text('全部书籍'), findsOneWidget);
      expect(find.text('Series One'), findsOneWidget);
      expect(find.text('已读 1 · 阅读中 1 · 未读 2'), findsOneWidget);
      expect(find.textContaining('ing'), findsNothing);
      expect(find.byType(GridView), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey<String>('komgaLinearReadProgress:series:series-1'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('全部书籍'));
      await _pumpFrames(tester);

      expect(find.text('Zulu Continue'), findsOneWidget);
      expect(find.text('Alpha Unread'), findsOneWidget);
      expect(find.text('Bravo Read'), findsOneWidget);
      expect(find.text('Charlie New'), findsOneWidget);
      expect(find.text('继续阅读 · 1/10'), findsOneWidget);
      expect(find.text('未读 · 共 10 页'), findsNWidgets(2));
      expect(find.text('已读完 · 共 10 页'), findsOneWidget);
      expect(find.text('新添加'), findsOneWidget);
      expect(client.allSeriesCalls, 1);
      expect(client.allBooksCalls, 1);
      expect(
        find.byKey(
          const ValueKey<String>('komgaLinearReadProgress:book:book-1'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('komgaLinearReadProgress:book:book-3'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('komgaCircularReadProgress:book:book-1'),
        ),
        findsNothing,
      );

      await tester.tap(find.byIcon(Icons.view_list_outlined));
      await _pumpFrames(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(GridView), findsNothing);
      expect(find.text('Zulu Continue'), findsOneWidget);
      expect(find.text('Alpha Unread'), findsOneWidget);
      expect(client.allBooksCalls, 1);
      expect(
        find.byKey(
          const ValueKey<String>('komgaLinearReadProgress:book:book-1'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey<String>('komgaCircularReadProgress:book:book-1'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('komgaCircularReadProgress:book:book-3'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byIcon(Icons.view_agenda_outlined));
      await _pumpFrames(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('添加于 2026-08-03'), findsOneWidget);
      expect(find.textContaining('application'), findsNothing);
      expect(client.allBooksCalls, 1);
      expect(
        find.byKey(
          const ValueKey<String>('komgaCircularReadProgress:book:book-1'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('komgaCircularReadProgress:book:book-3'),
        ),
        findsOneWidget,
      );

      await _selectProgressFilter(tester, '全部状态', '未读');
      expect(find.text('Alpha Unread'), findsOneWidget);
      expect(find.text('Charlie New'), findsOneWidget);
      expect(find.text('Zulu Continue'), findsNothing);
      expect(find.text('Bravo Read'), findsNothing);

      await _selectProgressFilter(tester, '未读', '阅读中');
      expect(find.text('Zulu Continue'), findsOneWidget);
      expect(find.text('Alpha Unread'), findsNothing);
      expect(find.text('Bravo Read'), findsNothing);

      await _selectProgressFilter(tester, '阅读中', '已读');
      expect(find.text('Bravo Read'), findsOneWidget);
      expect(find.text('Zulu Continue'), findsNothing);

      await _selectProgressFilter(tester, '已读', '新添加');
      expect(find.text('Charlie New'), findsOneWidget);
      expect(find.text('Alpha Unread'), findsNothing);
      expect(find.text('Zulu Continue'), findsNothing);
      expect(find.text('Bravo Read'), findsNothing);

      expect(client.allBooksCalls, 1);
    },
  );

  testWidgets('sort modes apply their real order in both directions', (
    WidgetTester tester,
  ) async {
    final _FakeKomgaClient client = _FakeKomgaClient();
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _openLibraryBooks(tester, client);
    await tester.tap(find.byIcon(Icons.view_list_outlined));
    await _pumpFrames(tester);

    const List<String> titles = <String>[
      'Zulu Continue',
      'Alpha Unread',
      'Bravo Read',
      'Charlie New',
    ];

    _expectVerticalOrder(tester, <String>[
      'Charlie New',
      'Zulu Continue',
      'Bravo Read',
      'Alpha Unread',
    ]);

    await tester.tap(find.byIcon(Icons.arrow_downward));
    await _pumpFrames(tester);
    _expectVerticalOrder(tester, <String>[
      'Alpha Unread',
      'Bravo Read',
      'Zulu Continue',
      'Charlie New',
    ]);

    await _selectSortMode(tester, '添加时间', '标题');
    _expectVerticalOrder(tester, <String>[
      'Alpha Unread',
      'Bravo Read',
      'Charlie New',
      'Zulu Continue',
    ]);

    await tester.tap(find.byIcon(Icons.arrow_upward));
    await _pumpFrames(tester);
    _expectVerticalOrder(tester, <String>[
      'Zulu Continue',
      'Charlie New',
      'Bravo Read',
      'Alpha Unread',
    ]);

    await _selectSortMode(tester, '标题', '最近阅读');
    _expectVerticalOrder(tester, <String>[
      'Zulu Continue',
      'Bravo Read',
      'Alpha Unread',
      'Charlie New',
    ]);

    await tester.tap(find.byIcon(Icons.arrow_downward));
    await _pumpFrames(tester);
    _expectVerticalOrder(tester, <String>[
      'Bravo Read',
      'Zulu Continue',
      'Alpha Unread',
      'Charlie New',
    ]);

    for (final String title in titles) {
      expect(find.text(title), findsOneWidget);
    }
    expect(client.allBooksCalls, 1);
  });

  testWidgets('deep library level keeps both drawer and back buttons', (
    WidgetTester tester,
  ) async {
    final _FakeKomgaClient client = _FakeKomgaClient();
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      GetMaterialApp(
        translations: LocaleText(),
        locale: const Locale('zh', 'CN'),
        home: KomgaPage(clientFactory: () => client),
      ),
    );
    await _pumpFrames(tester);
    expect(
      tester
          .widgetList<Text>(find.byType(Text))
          .map((Text widget) => widget.data),
      contains('Manga'),
    );
    await tester.tap(find.text('Manga'));
    await _pumpFrames(tester);

    expect(find.byIcon(Icons.menu), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);

    await tester.tap(find.byIcon(Icons.menu));
    await _pumpFrames(tester);
    expect(find.byType(Drawer), findsOneWidget);

    await tester.binding.handlePopRoute();
    await _pumpFrames(tester);
    expect(find.byType(Drawer), findsNothing);
    expect(find.text('Series One'), findsOneWidget);
    expect(find.text('Manga'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(client.allSeriesCalls, 1);
    expect(client.allBooksCalls, 1);
  });

  testWidgets('browse controls and detail view fit a phone-width layout', (
    WidgetTester tester,
  ) async {
    final _FakeKomgaClient client = _FakeKomgaClient();
    await tester.binding.setSurfaceSize(const Size(375, 812));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      GetMaterialApp(
        translations: LocaleText(),
        locale: const Locale('zh', 'CN'),
        builder: (BuildContext context, Widget? child) {
          return MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          );
        },
        home: KomgaPage(clientFactory: () => client),
      ),
    );
    await _pumpFrames(tester);
    await tester.tap(find.text('Manga'));
    await _pumpFrames(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('系列'), findsOneWidget);
    expect(find.text('全部书籍'), findsOneWidget);
    expect(find.byType(GridView), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('全部书籍'));
    await _pumpFrames(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.view_list_outlined));
    await _pumpFrames(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.view_agenda_outlined));
    await _pumpFrames(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Charlie New'), findsOneWidget);
  });

  testWidgets('dark browse toolbar uses the scaffold background color', (
    WidgetTester tester,
  ) async {
    final _FakeKomgaClient client = _FakeKomgaClient();
    const Color scaffoldColor = Color(0xFF101016);
    final ThemeData darkTheme = ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: scaffoldColor,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.deepPurple,
        brightness: Brightness.dark,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      GetMaterialApp(
        translations: LocaleText(),
        locale: const Locale('zh', 'CN'),
        themeMode: ThemeMode.dark,
        darkTheme: darkTheme,
        home: KomgaPage(clientFactory: () => client),
      ),
    );
    await _pumpFrames(tester);
    await tester.tap(find.text('Manga'));
    await _pumpFrames(tester);

    final Material toolbar = tester.widget<Material>(
      find.byKey(const ValueKey<String>('komgaBrowseToolbar')),
    );
    final BuildContext scaffoldContext = tester.element(find.byType(Scaffold));
    expect(Theme.of(scaffoldContext).brightness, Brightness.dark);
    expect(toolbar.color, Theme.of(scaffoldContext).scaffoldBackgroundColor);
    expect(toolbar.color, scaffoldColor);
  });

  testWidgets('pull-to-refresh forces cloud progress sync before reloading', (
    WidgetTester tester,
  ) async {
    final _FakeKomgaClient client = _FakeKomgaClient();
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      GetMaterialApp(
        translations: LocaleText(),
        locale: const Locale('zh', 'CN'),
        home: KomgaPage(clientFactory: () => client),
      ),
    );
    await _pumpFrames(tester);

    expect(fakeSyncService.readProgressSyncCalls, 1);
    expect(fakeSyncService.requests.single.requireAutoSync, isTrue);
    expect(fakeSyncService.requests.single.force, isFalse);
    expect(client.librariesCalls, 1);

    final RefreshIndicator indicator = tester.widget<RefreshIndicator>(
      find.byType(RefreshIndicator),
    );
    await indicator.onRefresh();
    await _pumpFrames(tester);

    expect(fakeSyncService.readProgressSyncCalls, 2);
    expect(fakeSyncService.requests.last.requireAutoSync, isFalse);
    expect(fakeSyncService.requests.last.force, isTrue);
    expect(client.librariesCalls, 2);
  });

  testWidgets('progress import action is directly left of refresh', (
    WidgetTester tester,
  ) async {
    final _FakeKomgaClient client = _FakeKomgaClient();
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      GetMaterialApp(
        translations: LocaleText(),
        locale: const Locale('zh', 'CN'),
        home: KomgaPage(clientFactory: () => client),
      ),
    );
    await _pumpFrames(tester);

    final Finder importButton = find.byKey(
      const ValueKey<String>('komgaImportProgressButton'),
    );
    final Finder refreshButton = find.widgetWithIcon(IconButton, Icons.refresh);
    final Finder settingsButton = find.widgetWithIcon(
      IconButton,
      Icons.settings_outlined,
    );
    expect(importButton, findsOneWidget);
    expect(find.byTooltip('导入 Komga 阅读进度'), findsOneWidget);
    expect(
      tester.getCenter(importButton).dx,
      lessThan(tester.getCenter(refreshButton).dx),
    );
    expect(
      tester.getCenter(refreshButton).dx,
      lessThan(tester.getCenter(settingsButton).dx),
    );
  });

  testWidgets(
    'progress import disables competing actions and merges server history',
    (WidgetTester tester) async {
      final _FakeKomgaClient client = _FakeKomgaClient();
      client.readProgressBooksCompleter = Completer<List<KomgaBook>>();
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await _openLibraryBooks(tester, client);
      expect(find.text('未读 · 共 10 页'), findsNWidgets(2));

      final Finder importButton = find.byKey(
        const ValueKey<String>('komgaImportProgressButton'),
      );
      await tester.tap(importButton);
      await tester.pump();

      expect(client.readProgressBooksCalls, 1);
      expect(
        find.descendant(
          of: importButton,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(tester.widget<IconButton>(importButton).onPressed, isNull);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.settings_outlined),
            )
            .onPressed,
        isNull,
      );
      final InkWell unreadBook = tester.widget<InkWell>(
        find
            .ancestor(
              of: find.text('Alpha Unread'),
              matching: find.byType(InkWell),
            )
            .first,
      );
      expect(unreadBook.onTap, isNull);

      client.readProgressBooksCompleter!.complete(<KomgaBook>[
        _book(
          'book-1',
          'Zulu Continue',
          DateTime.utc(2026, 8, 1),
          readProgress: <String, dynamic>{
            'page': 7,
            'completed': false,
            'readDate': '2026-08-01T08:00:00Z',
          },
        ),
        _book(
          'book-2',
          'Alpha Unread',
          DateTime.utc(2026, 7, 30),
          readProgress: <String, dynamic>{
            'page': 0,
            'completed': false,
            'readDate': '2026-08-05T10:00:00Z',
          },
        ),
        _book(
          'book-4',
          'Charlie New',
          DateTime.utc(2026, 8, 3),
          readProgress: <String, dynamic>{
            'page': 3,
            'completed': true,
            'lastModified': '2026-08-06T11:00:00Z',
          },
        ),
        _book(
          'book-without-time',
          'No Timestamp',
          DateTime.utc(2026, 8, 3),
          readProgress: <String, dynamic>{'page': 4, 'completed': false},
        ),
      ]);
      await _pumpFrames(tester);

      expect(
        find.descendant(
          of: importButton,
          matching: find.byIcon(Icons.cloud_download_outlined),
        ),
        findsOneWidget,
      );
      expect(tester.widget<IconButton>(importButton).onPressed, isNotNull);
      expect(find.text('继续阅读 · 1/10'), findsNWidgets(2));
      expect(find.text('已读完 · 共 10 页'), findsNWidgets(2));

      final ReadProgressEntry? olderLocal = await readProgressService
          .getReadProgressEntryByKey('komga:fixture-connection:book-1');
      final ReadProgressEntry? firstPage = await readProgressService
          .getReadProgressEntryByKey('komga:fixture-connection:book-2');
      final ReadProgressEntry? completed = await readProgressService
          .getReadProgressEntryByKey('komga:fixture-connection:book-4');
      final ReadProgressEntry? missingTime = await readProgressService
          .getReadProgressEntryByKey(
            'komga:fixture-connection:book-without-time',
          );
      expect(olderLocal?.pageIndex, 0);
      expect(olderLocal?.lastReadAt, DateTime.utc(2026, 8, 4, 10));
      expect(firstPage?.pageIndex, 0);
      expect(firstPage?.lastReadAt, DateTime.utc(2026, 8, 5, 10));
      expect(completed?.pageIndex, 9);
      expect(completed?.lastReadAt, DateTime.utc(2026, 8, 6, 11));
      expect(missingTime, isNull);
    },
  );

  testWidgets('stale server progress is discarded after configuration change', (
    WidgetTester tester,
  ) async {
    final _FakeKomgaClient oldClient = _FakeKomgaClient();
    final _FakeKomgaClient newClient = _FakeKomgaClient();
    oldClient.readProgressBooksCompleter = Completer<List<KomgaBook>>();
    _FakeKomgaClient activeClient = oldClient;
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      GetMaterialApp(
        translations: LocaleText(),
        locale: const Locale('zh', 'CN'),
        home: KomgaPage(clientFactory: () => activeClient),
      ),
    );
    await _pumpFrames(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('komgaImportProgressButton')),
    );
    await tester.pump();
    expect(oldClient.readProgressBooksCalls, 1);

    activeClient = newClient;
    komgaSetting.applyBeanConfig(
      jsonEncode(<String, dynamic>{
        'serverUrl': 'https://new-komga.test',
        'username': 'reader',
        'password': 'secret',
        'apiKey': '',
        'connectionId': 'new-connection',
      }),
    );
    await _pumpFrames(tester);

    oldClient.readProgressBooksCompleter!.complete(<KomgaBook>[
      _book(
        'stale-book',
        'Stale Book',
        DateTime.utc(2026, 8, 1),
        readProgress: <String, dynamic>{
          'page': 5,
          'completed': false,
          'readDate': '2026-08-05T10:00:00Z',
        },
      ),
    ]);
    await _pumpFrames(tester);

    expect(
      await readProgressService.getReadProgressEntryByKey(
        'komga:fixture-connection:stale-book',
      ),
      isNull,
    );
    expect(find.text('Manga'), findsOneWidget);
  });

  testWidgets('first visit baseline detects books added by a later refresh', (
    WidgetTester tester,
  ) async {
    final _FakeKomgaClient client = _FakeKomgaClient();
    client.books.removeWhere((KomgaBook book) => book.id == 'book-4');
    await localConfigService.write(
      configKey: ConfigEnum.komgaBrowseSetting,
      value: const KomgaBrowsePreferences().toJsonString(),
    );
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _openLibraryBooks(tester, client);
    expect(find.text('Charlie New'), findsNothing);
    expect(find.text('新添加'), findsNothing);

    client.books.add(_book('book-4', 'Charlie New', DateTime.utc(2026, 8, 3)));
    await tester.tap(find.byIcon(Icons.refresh));
    await _pumpFrames(tester);

    expect(find.text('Charlie New'), findsOneWidget);
    expect(find.text('新添加'), findsOneWidget);
    expect(client.allBooksCalls, 2);
  });

  testWidgets('cloud progress refresh updates visible reading status', (
    WidgetTester tester,
  ) async {
    final _FakeKomgaClient client = _FakeKomgaClient();
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _openLibraryBooks(tester, client);
    expect(find.text('未读 · 共 10 页'), findsNWidgets(2));

    await localConfigService.batchWrite(<LocalConfigCompanion>[
      _progressRow(
        'komga:fixture-connection:book-2',
        '9',
        '2026-08-05T10:00:00.000000Z',
      ),
    ]);
    readProgressService.clearCacheAndRefresh();
    await _pumpFrames(tester);

    expect(find.text('未读 · 共 10 页'), findsOneWidget);
    expect(find.text('已读完 · 共 10 页'), findsNWidgets(2));
  });

  testWidgets('leaving a loading library restores the root refresh action', (
    WidgetTester tester,
  ) async {
    final _FakeKomgaClient client = _FakeKomgaClient();
    client.allBooksCompleter = Completer<List<KomgaBook>>();
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      GetMaterialApp(
        translations: LocaleText(),
        locale: const Locale('zh', 'CN'),
        home: KomgaPage(clientFactory: () => client),
      ),
    );
    await _pumpFrames(tester);
    await tester.tap(find.text('Manga'));
    await tester.pump();
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    final IconButton refreshButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.refresh),
    );
    expect(refreshButton.onPressed, isNotNull);
    expect(find.text('Manga'), findsOneWidget);

    client.allBooksCompleter!.complete(client.books);
    await _pumpFrames(tester);
    expect(find.text('Manga'), findsOneWidget);
  });
}

LocalConfigCompanion _progressRow(String key, String value, String lastReadAt) {
  return LocalConfigCompanion(
    configKey: drift.Value(ConfigEnum.readIndexRecord.key),
    subConfigKey: drift.Value(key),
    value: drift.Value(value),
    utime: drift.Value(lastReadAt),
  );
}

Future<void> _openLibraryBooks(
  WidgetTester tester,
  _FakeKomgaClient client,
) async {
  await tester.pumpWidget(
    GetMaterialApp(
      translations: LocaleText(),
      locale: const Locale('zh', 'CN'),
      home: KomgaPage(clientFactory: () => client),
    ),
  );
  await _pumpFrames(tester);
  await tester.tap(find.text('Manga'));
  await _pumpFrames(tester);
  await tester.tap(find.text('全部书籍'));
  await _pumpFrames(tester);
}

Future<void> _selectProgressFilter(
  WidgetTester tester,
  String currentLabel,
  String nextLabel,
) async {
  await tester.tap(find.text(currentLabel).first);
  await _pumpFrames(tester);
  await tester.tap(find.text(nextLabel).last);
  await _pumpFrames(tester);
}

Future<void> _selectSortMode(
  WidgetTester tester,
  String currentLabel,
  String nextLabel,
) async {
  await tester.tap(find.text(currentLabel).first);
  await _pumpFrames(tester);
  await tester.tap(find.text(nextLabel).last);
  await _pumpFrames(tester);
}

void _expectVerticalOrder(WidgetTester tester, List<String> titles) {
  final List<double> offsets = titles
      .map((String title) => tester.getTopLeft(find.text(title)).dy)
      .toList();
  expect(offsets, orderedEquals(<double>[...offsets]..sort()));
}

Future<void> _pumpFrames(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

KomgaSeries _series() {
  return KomgaSeries.fromJson(<String, dynamic>{
    'id': 'series-1',
    'libraryId': 'library-1',
    'name': 'Series One',
    'booksCount': 4,
    'created': '2026-08-01T00:00:00Z',
    'metadata': <String, dynamic>{
      'title': 'Series One',
      'summary': 'Series summary',
      'tags': <String>['manga'],
    },
    'booksMetadata': <String, dynamic>{'authors': <dynamic>[]},
  });
}

KomgaBook _book(
  String id,
  String title,
  DateTime created, {
  Map<String, dynamic>? readProgress,
}) {
  return KomgaBook.fromJson(<String, dynamic>{
    'id': id,
    'seriesId': 'series-1',
    'seriesTitle': 'Series One',
    'name': '$id.cbz',
    'size': '12 MB',
    'created': created.toIso8601String(),
    'metadata': <String, dynamic>{
      'title': title,
      'number': id == 'book-1' ? '1' : '2',
      'summary': '$title summary',
      'authors': <dynamic>[],
      'tags': <String>['manga'],
    },
    'media': <String, dynamic>{
      'status': 'READY',
      'mediaType': 'application/zip',
      'mediaProfile': 'DIVINA',
      'pagesCount': 10,
    },
    if (readProgress != null) 'readProgress': readProgress,
  });
}
