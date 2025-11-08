# 云同步架构设计文档

## 📋 目录
1. [当前状态](#当前状态)
2. [存在的问题](#存在的问题)
3. [改进方案](#改进方案)
4. [实施计划](#实施计划)
5. [历史记录功能设计](#历史记录功能设计)

---

## 当前状态

### 系统概览

JHenTai 目前的云同步功能由以下组件组成：

#### 1. CloudConfigService (`lib/src/service/cloud_service.dart`)
**职责**：配置数据的导入导出逻辑
- 支持 5 种配置类型：
  - `readIndexRecord`（阅读进度）
  - `quickSearch`（快速搜索）
  - `searchHistory`（搜索历史）
  - `blockRules`（屏蔽规则）
  - `history`（浏览历史）
- 提供 `getLocalConfig()` 方法将本地数据导出为 `CloudConfig` 对象
- 提供 `importConfig()` 方法将 `CloudConfig` 对象导入本地数据库

#### 2. WebDavSyncService (`lib/src/service/webdav_sync_service.dart`)
**职责**：WebDAV 传输 + 增量同步合并逻辑

**核心功能**：
- WebDAV 文件上传/下载
- 时间戳比较确定同步方向
- **智能增量合并**（关键特性）：
  - 对于有时间戳的配置（`readIndexRecord`, `history`）：按条目时间戳合并
  - 对于无时间戳的配置（`quickSearch`, `blockRules`, `searchHistory`）：按文件时间戳合并
- 本地元数据管理（`JHenTaiConfig-metadata.json`）
- 统计信息追踪（`MergeStatistics`）

**实现细节**：
```
远程文件路径：{remotePath}/JHenTaiConfig.json
本地元数据：{tempDir}/JHenTaiConfig-metadata.json
```

#### 3. WebDavSetting (`lib/src/setting/webdav_setting.dart`)
**配置项**：
- `serverUrl`：WebDAV 服务器地址（默认坚果云）
- `username`：用户名
- `password`：密码
- `remotePath`：远程目录路径（默认 `/JHenTaiConfig`）
- `enableWebDav`：是否启用
- `autoSync`：是否自动同步

### Git 历史回顾

从 git 历史可以看出 WebDAV 同步功能的演进：

```
adc49fd - Add WebDAV config sync feature
  ├─ 基础实现：上传/下载 + 时间戳比较

f6efae4 - Add auto sync on app startup feature
  ├─ 添加启动自动同步

ee370dd - Implement incremental sync with smart merge logic
  ├─ 核心改进：增量合并逻辑
  ├─ 区分不同配置类型的合并策略
  └─ 添加统计信息
```

### 当前架构图

```
┌─────────────────────────────────────────────────────────┐
│                         UI Layer                         │
│              (setting_advanced_page.dart)                │
└────────────────────┬────────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────────┐
│              WebDavSyncService                           │
│  ┌─────────────────────────────────────────────────┐    │
│  │   传输层 (WebDAV Client)                        │    │
│  │   - uploadConfig()                              │    │
│  │   - downloadConfig()                            │    │
│  │   - getRemoteFileTime()                         │    │
│  └─────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────┐    │
│  │   同步逻辑层 (Merge Logic)                      │    │
│  │   - incrementalSync()                           │    │
│  │   - determineSyncDirection()                    │    │
│  │   - _mergeConfig()                              │    │
│  │   - _mergeReadIndexRecord()                     │    │
│  │   - _mergeQuickSearch()                         │    │
│  │   - _mergeBlockRules()                          │    │
│  │   - _mergeSearchHistory()                       │    │
│  │   - _mergeHistory()                             │    │
│  └─────────────────────────────────────────────────┘    │
└────────────────────┬────────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────────┐
│              CloudConfigService                          │
│   - getLocalConfig()   (数据导出)                       │
│   - importConfig()     (数据导入)                       │
└────────────────────┬────────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────────┐
│              Local Storage Layer                         │
│   - LocalConfigService                                   │
│   - QuickSearchService                                   │
│   - SearchHistoryService                                 │
│   - LocalBlockRuleService                                │
│   - HistoryService                                       │
└─────────────────────────────────────────────────────────┘
```

---

## 存在的问题

### 1. ❌ 缺乏抽象层
- **问题**：WebDAV 传输逻辑和合并逻辑耦合在同一个服务中
- **影响**：要添加新的云存储（S3、Google Drive 等）需要复制整个合并逻辑
- **示例**：`incrementalSync()` 方法既调用 WebDAV API，又处理数据合并

### 2. ❌ 无法扩展云存储提供商
- **问题**：没有统一的云存储接口
- **影响**：每添加一个新的云存储都需要重写整个服务
- **当前**：只有 WebDAV

### 3. ❌ 无历史记录功能
- **问题**：每次同步会覆盖远程文件，无法回滚到历史版本
- **影响**：如果同步出错，数据可能丢失
- **需求**：用户希望能够查看和恢复历史配置

### 4. ❌ 配置管理分散
- **问题**：WebDAV 设置存在独立的 `WebDavSetting`，未来 S3 也需要独立设置
- **影响**：没有统一的同步设置管理界面

---

## 改进方案

### 核心设计原则

> **关注点分离**：将数据处理逻辑和云存储传输逻辑彻底分离

### 新架构设计

```
┌─────────────────────────────────────────────────────────┐
│                         UI Layer                         │
│              (setting_sync_page.dart)                    │
│   ┌─────────────────────────────────────────────────┐   │
│   │  Provider Selection:  [S3] [WebDAV]             │   │
│   │  S3 Settings: Endpoint, Bucket, Access Key...   │   │
│   │  WebDAV Settings: Server URL, Username...       │   │
│   │  History: View, Restore, Delete                 │   │
│   └─────────────────────────────────────────────────┘   │
└────────────────────┬────────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────────┐
│              SyncService (统一同步服务)                  │
│  ┌─────────────────────────────────────────────────┐    │
│  │   同步协调层                                    │    │
│  │   - sync(provider, types)                       │    │
│  │   - autoSync()                                  │    │
│  │   - listHistory(provider)                       │    │
│  │   - restoreFromHistory(provider, version)       │    │
│  └─────────────────────────────────────────────────┘    │
└────────────────────┬────────────────────────────────────┘
                     │
        ┌────────────┴────────────┐
        │                         │
┌───────▼────────┐       ┌───────▼────────┐
│ SyncMerger     │       │ CloudProvider  │
│ (合并逻辑)     │       │ (抽象接口)     │
└────────────────┘       └───────┬────────┘
                                 │
                    ┌────────────┼────────────┐
                    │            │            │
            ┌───────▼──────┐ ┌──▼─────┐ ┌───▼──────┐
            │ S3Provider   │ │WebDAV  │ │ Future   │
            │ (R2/S3/Minio)│ │Provider│ │ Providers│
            └──────────────┘ └────────┘ └──────────┘
```

### 1. 抽象层设计

#### 1.1 CloudProvider 接口

```dart
/// 云存储提供商抽象接口
abstract class CloudProvider {
  /// 提供商名称
  String get name;

  /// 是否已启用
  bool get isEnabled;

  /// 上传配置文件
  /// [data]: JSON 字符串
  /// [saveHistory]: 是否同时保存历史版本（默认 false）
  /// 返回上传后的文件元数据
  Future<CloudFile> upload(String data, {bool saveHistory = false});

  /// 下载最新配置文件
  Future<String> download();

  /// 下载指定历史版本
  /// [version]: 版本标识（时间戳格式）
  Future<String> downloadVersion(String version);

  /// 列出所有历史版本
  Future<List<CloudFile>> listVersions();

  /// 删除指定历史版本
  /// [version]: 版本标识（时间戳格式）
  Future<void> deleteVersion(String version);

  /// 获取最新文件的元数据（修改时间等）
  Future<CloudFile?> getFileMetadata();

  /// 测试连接
  Future<bool> testConnection();
}

/// 云文件元数据
class CloudFile {
  final String version;        // 版本标识（时间戳或 'latest'）
  final DateTime modifiedTime; // 修改时间
  final int size;              // 文件大小（字节）
  final String? etag;          // ETag（可选，用于缓存验证）

  CloudFile({
    required this.version,
    required this.modifiedTime,
    required this.size,
    this.etag,
  });
}
```

#### 1.2 SyncMerger 服务（数据合并逻辑）

```dart
/// 同步合并服务（独立于传输层）
class SyncMerger {
  /// 执行增量合并
  /// [localConfigs]: 本地配置列表
  /// [remoteConfigs]: 远程配置列表
  /// [remoteFileTime]: 远程文件修改时间
  /// 返回合并后的配置和统计信息
  Future<MergeResult> merge(
    List<CloudConfig> localConfigs,
    List<CloudConfig> remoteConfigs,
    DateTime remoteFileTime,
  );

  /// 合并单个配置类型
  Future<MergeResult> mergeConfigType(
    CloudConfigTypeEnum type,
    CloudConfig? local,
    CloudConfig? remote,
    DateTime remoteFileTime,
  );

  // 私有方法（从 WebDavSyncService 迁移）
  Future<MergeResult> _mergeReadIndexRecord(...);
  Future<MergeResult> _mergeQuickSearch(...);
  Future<MergeResult> _mergeBlockRules(...);
  Future<MergeResult> _mergeSearchHistory(...);
  Future<MergeResult> _mergeHistory(...);
}

class MergeResult {
  final List<CloudConfig> merged;
  final Map<CloudConfigTypeEnum, MergeStatistics> statistics;

  MergeResult(this.merged, this.statistics);
}
```

#### 1.3 SyncService 统一服务

```dart
/// 统一同步服务（协调层）
class SyncService {
  final SyncMerger _merger;
  final Map<String, CloudProvider> _providers;

  /// 执行同步
  Future<SyncResult> sync({
    required String providerName,
    required List<CloudConfigTypeEnum> types,
  }) async {
    CloudProvider provider = _providers[providerName];

    // 1. 获取本地配置
    List<CloudConfig> localConfigs = await _getLocalConfigs(types);

    // 2. 下载远程配置
    List<CloudConfig> remoteConfigs = [];
    CloudFile? remoteFile = await provider.getFileMetadata();
    if (remoteFile != null) {
      String data = await provider.download();
      remoteConfigs = _parseConfigs(data);
    }

    // 3. 合并配置
    MergeResult mergeResult = await _merger.merge(
      localConfigs,
      remoteConfigs,
      remoteFile?.modifiedTime ?? DateTime.now(),
    );

    // 4. 导入合并结果到本地
    await _importConfigs(mergeResult.merged);

    // 5. 上传合并结果
    // saveHistory 由用户设置决定（默认 false）
    bool saveHistory = syncSetting.enableHistory.value;
    await provider.upload(
      _encodeConfigs(mergeResult.merged),
      saveHistory: saveHistory,
    );

    // 6. 如果启用了历史记录且需要自动清理
    if (saveHistory && syncSetting.autoCleanHistory.value) {
      await _cleanupOldVersions(provider);
    }

    return SyncResult(success: true, statistics: mergeResult.statistics);
  }

  /// 列出历史版本
  Future<List<CloudFile>> listHistory(String providerName) async {
    CloudProvider provider = _providers[providerName];
    return await provider.listVersions();
  }

  /// 从历史版本恢复配置
  Future<RestoreResult> restoreFromHistory({
    required String providerName,
    required String version,
    bool syncToCloud = true,
  }) async {
    try {
      CloudProvider provider = _providers[providerName];

      // 1. 下载指定历史版本
      String data = await provider.downloadVersion(version);
      List configs = await isolateService.jsonDecodeAsync(data);
      List<CloudConfig> cloudConfigs = configs.map((e) => CloudConfig.fromJson(e)).toList();

      // 2. 导入到本地（替换当前配置）
      for (var config in cloudConfigs) {
        await cloudConfigService.importConfig(config);
      }

      // 3. （可选）同步到云端，使恢复的版本成为最新版本
      if (syncToCloud) {
        await provider.upload(data, saveHistory: syncSetting.enableHistory.value);
      }

      log.info('Restored from version: $version');
      return RestoreResult(success: true, version: version);
    } catch (e) {
      log.error('Failed to restore from history', e);
      return RestoreResult(success: false, error: e.toString());
    }
  }

  /// 清理超出数量限制的旧版本
  Future<void> _cleanupOldVersions(CloudProvider provider) async {
    // 详见「自动清理策略」章节
  }
}
```

### 2. 具体实现

#### 2.1 S3Provider 实现

使用 `minio` package（兼容 S3 API）：

```dart
class S3Provider implements CloudProvider {
  final Minio _client;
  final String _bucketName;
  final String _baseKey;  // 对象键前缀，如 "jhentai-sync/"

  S3Provider({
    required String endpoint,
    required String accessKey,
    required String secretKey,
    required String bucketName,
    required String region,
    String baseKey = 'jhentai-sync/',
  }) : _bucketName = bucketName,
       _baseKey = baseKey,
       _client = Minio(
         endPoint: endpoint,
         accessKey: accessKey,
         secretKey: secretKey,
         region: region,
       );

  @override
  String get name => 's3';

  @override
  Future<CloudFile> upload(String data, {bool saveHistory = false}) async {
    Uint8List bytes = Uint8List.fromList(utf8.encode(data));

    // 1. 总是上传 latest.json（最新版本）
    await _client.putObject(
      _bucketName,
      '${_baseKey}latest.json',
      Stream.value(bytes),
      size: bytes.length,
      metadata: {'content-type': 'application/json'},
    );

    // 2. 如果启用历史版本，额外保存带时间戳的文件
    String? version;
    if (saveHistory) {
      version = _generateVersion();
      await _client.putObject(
        _bucketName,
        '$_baseKey$version.json',
        Stream.value(bytes),
        size: bytes.length,
        metadata: {
          'content-type': 'application/json',
          'x-jhentai-version': version,
        },
      );
    }

    return CloudFile(
      version: version ?? 'latest',
      modifiedTime: DateTime.now(),
      size: bytes.length,
    );
  }

  @override
  Future<String> download() async {
    // 总是下载 latest.json
    var stream = await _client.getObject(_bucketName, '${_baseKey}latest.json');
    List<int> bytes = await stream.expand((chunk) => chunk).toList();
    return utf8.decode(bytes);
  }

  @override
  Future<String> downloadVersion(String version) async {
    // 下载指定的历史版本
    var stream = await _client.getObject(_bucketName, '$_baseKey$version.json');
    List<int> bytes = await stream.expand((chunk) => chunk).toList();
    return utf8.decode(bytes);
  }

  @override
  Future<List<CloudFile>> listVersions() async {
    List<CloudFile> versions = [];

    // 通过文件名模式匹配历史版本
    var objects = await _client.listObjects(
      _bucketName,
      prefix: _baseKey,
    ).toList();

    // 正则匹配时间戳格式的文件名（yyyyMMddHHmmss.json）
    final versionPattern = RegExp(r'^\d{14}\.json$');

    for (var obj in objects) {
      if (obj.key != null) {
        String fileName = obj.key!.replaceFirst(_baseKey, '');

        // 只处理时间戳格式的文件，跳过 latest.json
        if (versionPattern.hasMatch(fileName)) {
          String version = fileName.replaceFirst('.json', '');

          versions.add(CloudFile(
            version: version,
            modifiedTime: obj.lastModified ?? DateTime.now(),
            size: obj.size ?? 0,
            etag: obj.eTag,
          ));
        }
      }
    }

    // 按时间倒序排序（新版本在前）
    versions.sort((a, b) => b.version.compareTo(a.version));
    return versions;
  }

  @override
  Future<void> deleteVersion(String version) async {
    await _client.removeObject(_bucketName, '$_baseKey$version.json');
  }

  @override
  Future<CloudFile?> getFileMetadata({String? version}) async {
    try {
      String key = version != null
        ? '$_baseKey$version.json'
        : '${_baseKey}latest.json';

      var stat = await _client.statObject(_bucketName, key);
      return CloudFile(
        version: version ?? 'latest',
        modifiedTime: stat.lastModified ?? DateTime.now(),
        size: stat.size ?? 0,
        etag: stat.eTag,
      );
    } catch (e) {
      return null;
    }
  }

  @override
  Future<bool> testConnection() async {
    try {
      await _client.bucketExists(_bucketName);
      return true;
    } catch (e) {
      return false;
    }
  }

  String _generateVersion() {
    return DateFormat('yyyyMMddHHmmss').format(DateTime.now());
  }
}
```

#### 2.2 WebDavProvider 实现（重构现有代码）

```dart
class WebDavProvider implements CloudProvider {
  final webdav.Client _client;
  final String _remotePath;

  WebDavProvider({
    required String serverUrl,
    required String username,
    required String password,
    required String remotePath,
  }) : _remotePath = remotePath,
       _client = webdav.newClient(
         serverUrl,
         user: username,
         password: password,
       );

  @override
  String get name => 'webdav';

  @override
  Future<CloudFile> upload(String data, {bool saveHistory = false}) async {
    Uint8List bytes = Uint8List.fromList(utf8.encode(data));

    // 1. 总是上传 JHenTaiConfig.json（最新版本）
    String latestFile = '$_remotePath/JHenTaiConfig.json';
    await _client.write(latestFile, bytes);

    // 2. 如果启用历史版本，额外保存带时间戳的文件
    String? version;
    if (saveHistory) {
      version = _generateVersion();
      String versionFile = '$_remotePath/JHenTaiConfig-$version.json';
      await _client.write(versionFile, bytes);
    }

    return CloudFile(
      version: version ?? 'latest',
      modifiedTime: DateTime.now(),
      size: bytes.length,
    );
  }

  @override
  Future<String> download() async {
    // 总是下载 JHenTaiConfig.json
    var bytes = await _client.read('$_remotePath/JHenTaiConfig.json');
    return utf8.decode(bytes);
  }

  @override
  Future<String> downloadVersion(String version) async {
    // 下载指定的历史版本
    var bytes = await _client.read('$_remotePath/JHenTaiConfig-$version.json');
    return utf8.decode(bytes);
  }

  @override
  Future<List<CloudFile>> listVersions() async {
    List<webdav.File> files = await _client.readDir(_remotePath);
    List<CloudFile> versions = [];

    for (var file in files) {
      if (file.name != null &&
          file.name!.startsWith('JHenTaiConfig-') &&
          file.name!.endsWith('.json')) {
        String version = file.name!
          .replaceFirst('JHenTaiConfig-', '')
          .replaceFirst('.json', '');

        versions.add(CloudFile(
          version: version,
          modifiedTime: file.mTime ?? DateTime.now(),
          size: file.size ?? 0,
        ));
      }
    }

    versions.sort((a, b) => b.modifiedTime.compareTo(a.modifiedTime));
    return versions;
  }

  @override
  Future<void> deleteVersion(String version) async {
    await _client.remove('$_remotePath/JHenTaiConfig-$version.json');
  }

  @override
  Future<CloudFile?> getFileMetadata({String? version}) async {
    try {
      String file = version != null
        ? '$_remotePath/JHenTaiConfig-$version.json'
        : '$_remotePath/JHenTaiConfig.json';

      List<webdav.File> files = await _client.readDir(_remotePath);
      webdav.File? targetFile = files.firstWhere(
        (f) => f.path == file,
        orElse: () => throw Exception('File not found'),
      );

      return CloudFile(
        version: version ?? 'latest',
        modifiedTime: targetFile.mTime ?? DateTime.now(),
        size: targetFile.size ?? 0,
      );
    } catch (e) {
      return null;
    }
  }

  @override
  Future<bool> testConnection() async {
    try {
      await _client.ping();
      return true;
    } catch (e) {
      return false;
    }
  }

  String _generateVersion() {
    return DateFormat('yyyyMMddHHmmss').format(DateTime.now());
  }
}
```

### 3. 设置管理

#### 3.1 统一设置类

```dart
class SyncSetting {
  // 通用设置
  RxString currentProvider = 's3'.obs;  // 默认 S3
  RxBool autoSync = false.obs;

  // S3 设置
  RxBool enableS3 = false.obs;
  RxString s3Endpoint = ''.obs;         // 例如：<account-id>.r2.cloudflarestorage.com
  RxString s3AccessKey = ''.obs;
  RxString s3SecretKey = ''.obs;
  RxString s3BucketName = 'jhentai-sync'.obs;
  RxString s3Region = 'auto'.obs;       // R2 使用 'auto'
  RxString s3BaseKey = 'jhentai-sync/'.obs;

  // WebDAV 设置（保留现有）
  RxBool enableWebDav = false.obs;
  RxString webdavServerUrl = 'https://dav.jianguoyun.com/dav/'.obs;
  RxString webdavUsername = ''.obs;
  RxString webdavPassword = ''.obs;
  RxString webdavRemotePath = '/JHenTaiConfig'.obs;

  // 历史记录设置
  RxInt maxHistoryVersions = 10.obs;    // 最多保留 10 个历史版本
  RxBool autoCleanHistory = true.obs;   // 自动清理旧版本
}
```

#### 3.2 UI 改进

新建 `setting_sync_page.dart` 替代当前在 advanced settings 的实现：

```dart
// 同步设置页面
SyncSettingPage
  ├─ Provider 选择 Dropdown: [S3 (Cloudflare R2)] [WebDAV]
  ├─ 当前 Provider 的设置面板
  │   ├─ S3 Panel (当选择 S3 时)
  │   │   ├─ Enable toggle
  │   │   ├─ Endpoint input
  │   │   ├─ Access Key input
  │   │   ├─ Secret Key input
  │   │   ├─ Bucket Name input
  │   │   ├─ Region input
  │   │   ├─ Test Connection button
  │   │
  │   └─ WebDAV Panel (当选择 WebDAV 时)
  │       ├─ Enable toggle
  │       ├─ Server URL input
  │       ├─ Username input
  │       ├─ Password input
  │       ├─ Remote Path input
  │       └─ Test Connection button
  │
  ├─ 通用设置
  │   ├─ Auto sync toggle
  │   └─ Manual sync button (with type selection)
  │
  └─ 历史记录管理
      ├─ 历史版本列表
      │   ├─ 版本时间戳
      │   ├─ 文件大小
      │   └─ 操作按钮：预览、恢复、删除
      ├─ 最大历史版本数设置
      └─ 清理历史按钮
```

---

## 实施计划

### Phase 1: 重构现有代码（无功能变更）

#### 1.1 提取 SyncMerger 服务
**文件**：`lib/src/service/sync_merger.dart`

**任务**：
- 从 `WebDavSyncService` 中提取所有 `_merge*` 方法
- 创建独立的 `SyncMerger` 服务
- 保持原有合并逻辑不变

**预计工作量**：2-3 小时

#### 1.2 创建 CloudProvider 接口
**文件**：`lib/src/service/cloud/cloud_provider.dart`

**任务**：
- 定义 `CloudProvider` 抽象类
- 定义 `CloudFile` 模型

**预计工作量**：1 小时

#### 1.3 重构 WebDavSyncService 为 WebDavProvider
**文件**：`lib/src/service/cloud/webdav_provider.dart`

**任务**：
- 实现 `CloudProvider` 接口
- 保留现有 WebDAV 功能
- 添加历史版本支持（通过文件命名）
- 单元测试

**预计工作量**：4-5 小时

### Phase 2: 实现 S3 支持

#### 2.1 添加依赖
**文件**：`pubspec.yaml`

```yaml
dependencies:
  minio: ^4.0.5  # S3 兼容客户端
```

#### 2.2 实现 S3Provider
**文件**：`lib/src/service/cloud/s3_provider.dart`

**任务**：
- 实现 `CloudProvider` 接口
- 支持 Cloudflare R2 / AWS S3 / MinIO
- 历史版本管理
- 单元测试

**预计工作量**：6-8 小时

#### 2.3 创建 SyncSetting
**文件**：`lib/src/setting/sync_setting.dart`

**任务**：
- 合并 `WebDavSetting` 到统一设置
- 添加 S3 相关配置
- 持久化设置

**预计工作量**：3-4 小时

### Phase 3: 统一同步服务

#### 3.1 实现 SyncService
**文件**：`lib/src/service/sync_service.dart`

**任务**：
- 协调 Provider 和 Merger
- 实现统一的 `sync()` 方法
- 历史版本管理
- 自动同步功能

**预计工作量**：5-6 小时

#### 3.2 更新依赖注入
**文件**：`lib/src/main.dart`

**任务**：
- 注册新服务
- 保持向后兼容

**预计工作量**：1 小时

### Phase 4: UI 更新

#### 4.1 创建统一同步设置页面
**文件**：`lib/src/pages/setting/sync/setting_sync_page.dart`

**任务**：
- Provider 选择器
- S3 设置面板
- WebDAV 设置面板
- 通用设置
- 历史版本管理 UI

**预计工作量**：8-10 小时

#### 4.2 添加国际化
**文件**：`lib/src/l18n/en_US.dart`, `lib/src/l18n/zh_CN.dart`

**任务**：
- S3 相关文本
- 历史版本相关文本

**预计工作量**：2 小时

### Phase 5: 测试与优化

#### 5.1 集成测试
- 测试 S3 上传/下载
- 测试 WebDAV 上传/下载
- 测试增量合并
- 测试历史版本功能
- 测试 Provider 切换

**预计工作量**：6-8 小时

#### 5.2 文档更新
- 更新用户文档
- 添加 S3/R2 配置指南
- 添加 API 文档

**预计工作量**：3-4 小时

---

## 历史记录功能设计

### 版本控制策略选择

**决策：使用时间戳文件名，而非 S3 原生版本控制**

**原因**：
1. **R2 限制**：Cloudflare R2（推荐默认）不支持 S3 的原生版本控制功能
2. **统一体验**：所有 provider（S3/R2/WebDAV）使用一致的版本管理方式
3. **代码简化**：无需处理两种不同的版本管理模式
4. **可见性**：用户可以直接在云存储界面看到历史文件列表
5. **可移植性**：方便在不同 provider 之间迁移数据

**实现方式**：
- 每次同步上传两个文件：
  - 历史版本：`{baseKey}/{timestamp}.json`（如 `jhentai-sync/20251108143025.json`）
  - 最新版本：`{baseKey}/latest.json`（快捷访问）
- 通过文件名模式匹配列出历史版本
- 自动清理超过保留数量的旧版本

### 功能需求

**重要说明**：历史版本功能是**可选的独立功能**，默认关闭。不启用时，同步行为与当前 WebDAV 完全一致。

#### 核心功能

1. **自动保存历史**（可选）
   - 启用后，每次同步时额外保存一个带时间戳的副本
   - 不启用时，只操作 `latest.json`，无额外开销

2. **版本列表**
   - 展示所有历史版本（时间、大小）
   - 按时间倒序排列

3. **版本预览**
   - 查看某个历史版本的内容（只读）
   - 显示每种配置类型的数据统计

4. **版本恢复**（关键功能）
   - 用户选择一个历史版本
   - 将该版本的配置恢复为当前本地配置
   - 可选：恢复后是否同步到云端

5. **版本数量限制**（关键功能）
   - 用户设置保留的最大版本数（默认 10）
   - 上传新版本后自动清理超出数量的旧版本
   - 按时间排序，删除最旧的版本

6. **手动清理**
   - 用户可以手动删除单个历史版本
   - 一键清空所有历史版本

### 版本命名策略

**格式**：`yyyyMMddHHmmss`（例如：20251108143025）

**优点**：
- 时间可排序（自然排序即为时间顺序）
- 人类可读（一眼看出同步时间）
- 跨平台兼容（无特殊字符）
- 作为文件名安全（符合所有云存储命名规范）

### 存储策略

#### S3/R2
```
Bucket: jhentai-sync
Objects:
  ├─ jhentai-sync/latest.json           (最新版本的快捷方式)
  ├─ jhentai-sync/20251108143025.json   (历史版本 1)
  ├─ jhentai-sync/20251108133010.json   (历史版本 2)
  └─ jhentai-sync/20251108123005.json   (历史版本 3)
```

#### WebDAV
```
Remote Path: /JHenTaiConfig/
Files:
  ├─ JHenTaiConfig.json                  (最新版本)
  ├─ JHenTaiConfig-20251108143025.json   (历史版本 1)
  ├─ JHenTaiConfig-20251108133010.json   (历史版本 2)
  └─ JHenTaiConfig-20251108123005.json   (历史版本 3)
```

### 版本恢复功能实现

#### 恢复流程

```dart
/// 从历史版本恢复配置
/// [providerName]: 云存储提供商名称
/// [version]: 要恢复的版本号（时间戳）
/// [syncToCloud]: 恢复后是否同步到云端（默认 true）
Future<RestoreResult> restoreFromHistory({
  required String providerName,
  required String version,
  bool syncToCloud = true,
}) async {
  try {
    CloudProvider provider = _providers[providerName];

    // 1. 下载指定历史版本
    String data = await provider.downloadVersion(version);
    List configs = await isolateService.jsonDecodeAsync(data);
    List<CloudConfig> cloudConfigs = configs.map((e) => CloudConfig.fromJson(e)).toList();

    // 2. 导入到本地（替换当前配置）
    for (var config in cloudConfigs) {
      await cloudConfigService.importConfig(config);
    }

    // 3. （可选）同步到云端，使恢复的版本成为最新版本
    if (syncToCloud) {
      await provider.upload(data, saveHistory: syncSetting.enableHistory.value);
    }

    log.info('Restored from version: $version');
    return RestoreResult(success: true, version: version);
  } catch (e) {
    log.error('Failed to restore from history', e);
    return RestoreResult(success: false, error: e.toString());
  }
}

class RestoreResult {
  final bool success;
  final String? version;
  final String? error;

  RestoreResult({required this.success, this.version, this.error});
}
```

#### 恢复确认对话框

在 UI 中，恢复操作前应显示确认对话框：

```
┌─────────────────────────────────────────────────────────┐
│          Restore from History Version?                  │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  Version: 2025-11-08 14:30:25                           │
│                                                          │
│  ⚠️  Warning:                                            │
│  This will replace your current configuration with      │
│  the selected history version. This action cannot be    │
│  undone.                                                 │
│                                                          │
│  □ Sync to cloud after restore                          │
│     (Make this version the new latest version)          │
│                                                          │
├─────────────────────────────────────────────────────────┤
│                    [Cancel] [Restore]                    │
└─────────────────────────────────────────────────────────┘
```

### 自动清理策略

**默认策略**：保留最近 10 个版本

**触发时机**：
- 每次上传新版本后自动执行
- 仅在启用了「历史版本」和「自动清理」时执行

**清理逻辑**：
1. 列出所有历史版本
2. 按时间戳排序（新→旧）
3. 保留前 N 个版本（N = maxHistoryVersions）
4. 删除超出的旧版本

**代码实现**：
```dart
/// 清理超出数量限制的旧版本
Future<void> _cleanupOldVersions(CloudProvider provider) async {
  // 检查是否启用自动清理
  if (!syncSetting.enableHistory.value || !syncSetting.autoCleanHistory.value) {
    return;
  }

  try {
    // 列出所有历史版本
    List<CloudFile> versions = await provider.listVersions();
    int maxVersions = syncSetting.maxHistoryVersions.value;

    log.info('Found ${versions.length} history versions, max allowed: $maxVersions');

    if (versions.length > maxVersions) {
      // 按时间倒序排序（新版本在前）
      versions.sort((a, b) => b.version.compareTo(a.version));

      // 删除超出限制的旧版本
      int deletedCount = 0;
      for (int i = maxVersions; i < versions.length; i++) {
        await provider.deleteVersion(versions[i].version);
        log.info('Deleted old version: ${versions[i].version}');
        deletedCount++;
      }

      log.info('Cleaned up $deletedCount old versions');
    }
  } catch (e) {
    log.error('Failed to cleanup old versions', e);
    // 清理失败不影响主流程，只记录错误
  }
}
```

### 版本数量设置

#### 设置项

```dart
class SyncSetting {
  // 历史版本功能
  RxBool enableHistory = false.obs;           // 是否启用历史版本保存
  RxInt maxHistoryVersions = 10.obs;          // 保留的最大版本数（默认 10）
  RxBool autoCleanHistory = true.obs;         // 自动清理旧版本（默认开启）
}
```

#### UI 控件

```
┌─────────────────────────────────────────────────────────┐
│  📜 History Version Settings                             │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  Enable History: [OFF]  ← 主开关                         │
│                                                          │
│  (启用后显示以下选项：)                                   │
│                                                          │
│  Max History Versions: [10] ← 可调整 1-50               │
│    Keep up to 10 most recent versions                   │
│                                                          │
│  Auto Cleanup: [ON]                                      │
│    Automatically delete oldest versions when exceeding   │
│    the maximum count                                     │
│                                                          │
│  Current History Usage: 5 / 10 versions (2.5 MB)        │
│                                                          │
│  [View History]  [Clear All History]                    │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### UI 设计

#### 历史版本列表

点击「View History」按钮后显示：

```
┌─────────────────────────────────────────────────────────┐
│                    Sync History                          │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  📅 2025-11-08 14:30:25          125 KB                 │
│     阅读进度: 153项 | 快速搜索: 12项 | 浏览历史: 2340项 │
│     [Preview] [Restore] [Delete]                        │
│                                                          │
│  📅 2025-11-08 13:30:10          124 KB                 │
│     阅读进度: 150项 | 快速搜索: 12项 | 浏览历史: 2330项 │
│     [Preview] [Restore] [Delete]                        │
│                                                          │
│  📅 2025-11-08 12:30:05          120 KB                 │
│     阅读进度: 145项 | 快速搜索: 11项 | 浏览历史: 2320项 │
│     [Preview] [Restore] [Delete]                        │
│                                                          │
├─────────────────────────────────────────────────────────┤
│  Showing 3 / 3 versions                                  │
│  [Close]                                                 │
└─────────────────────────────────────────────────────────┘
```

**按钮功能**：
- **Preview**：查看该版本的详细内容（只读）
- **Restore**：恢复到该版本（显示确认对话框）
- **Delete**：删除该历史版本（显示确认对话框）

#### 版本预览对话框
```
┌─────────────────────────────────────────────────────────┐
│          Version Preview: 2025-11-08 14:30:25           │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  📖 Reading Progress (153 items)                        │
│     ├─ Gallery 12345: Page 15                          │
│     ├─ Gallery 67890: Page 8                           │
│     └─ ...                                              │
│                                                          │
│  🔍 Quick Search (12 items)                             │
│     ├─ "artist:foo"                                     │
│     ├─ "tag:bar"                                        │
│     └─ ...                                              │
│                                                          │
│  ⏱️ History (2340 items)                                │
│  🚫 Block Rules (5 items)                               │
│  📝 Search History (50 items)                           │
│                                                          │
├─────────────────────────────────────────────────────────┤
│                    [Restore] [Close]                     │
└─────────────────────────────────────────────────────────┘
```

---

## 迁移指南（用户）

### 从 WebDAV 迁移到 S3/R2

#### 步骤 1：准备 Cloudflare R2 账户
1. 登录 Cloudflare Dashboard
2. 创建 R2 Bucket（例如 `jhentai-sync`）
3. 生成 API Token（Access Key + Secret Key）
4. 记录 Endpoint（格式：`<account-id>.r2.cloudflarestorage.com`）

#### 步骤 2：配置 S3 同步
1. 打开 JHenTai 设置
2. 进入「同步设置」
3. 选择「S3 (Cloudflare R2)」
4. 填写配置：
   - Endpoint: `xxxxxx.r2.cloudflarestorage.com`
   - Access Key: `your-access-key`
   - Secret Key: `your-secret-key`
   - Bucket Name: `jhentai-sync`
   - Region: `auto`
5. 点击「测试连接」确保配置正确
6. 启用 S3 同步

#### 步骤 3：首次同步
1. 确保 WebDAV 同步已关闭（或保持开启以双向备份）
2. 点击「手动同步」
3. 选择所有配置类型
4. 执行同步

#### 步骤 4：验证
1. 查看「同步历史」确认版本已上传
2. 在其他设备上配置相同的 S3 设置并同步

### 继续使用 WebDAV

现有功能保持不变，但增加了历史版本功能：
- 每次同步会保存一个带时间戳的历史文件
- 可以在「同步历史」中查看和恢复

---

## Cloudflare R2 优势

### 为什么选择 R2 作为默认？

1. **成本**：
   - 免费额度：10 GB 存储 / 每月
   - 配置文件很小（通常 < 1 MB），基本免费
   - 无出口流量费用（egress free）

2. **性能**：
   - 全球分布式存储
   - 低延迟访问

3. **兼容性**：
   - 完全兼容 S3 API
   - 可以无缝切换到其他 S3 兼容服务

4. **易用性**：
   - Cloudflare 账户管理简单
   - 无需信用卡（免费额度内）

### S3 兼容服务对比

| 服务 | 免费额度 | 优点 | 缺点 |
|------|---------|------|------|
| **Cloudflare R2** | 10 GB 免费 | 无出口费用、速度快 | 需要 Cloudflare 账户 |
| **AWS S3** | 5 GB / 12 个月 | 稳定性最高 | 12 个月后收费、出口费用高 |
| **MinIO** | 自托管 | 完全控制 | 需要自己维护服务器 |
| **Backblaze B2** | 10 GB 免费 | 便宜 | 速度较慢 |
| **Wasabi** | 无免费额度 | 便宜 | 最低消费 $5.99/月 |

---

## 总结

### 改进后的架构优势

1. ✅ **高扩展性**：通过 `CloudProvider` 接口轻松添加新的云存储
2. ✅ **关注点分离**：数据合并逻辑（`SyncMerger`）与传输逻辑（`Provider`）分离
3. ✅ **向后兼容**：保留 WebDAV 功能，用户可以继续使用
4. ✅ **历史记录**：支持版本管理，防止数据丢失
5. ✅ **多 Provider 支持**：用户可以选择最适合的云存储方案
6. ✅ **统一管理**：一个设置页面管理所有同步相关配置

### 下一步

请review这个设计文档，确认以下内容：

1. **架构设计**：抽象层设计是否合理？
2. **S3 实现**：S3Provider 的实现方式是否满足需求？
3. **历史记录**：版本管理策略是否符合预期？
4. **UI 设计**：设置页面的布局是否合理？
5. **迁移影响**：对现有用户的影响是否可接受？

确认后我将开始实施 Phase 1。
