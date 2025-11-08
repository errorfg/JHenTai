/// 云存储提供商抽象接口
/// 定义统一的云存储操作接口，支持多种云存储后端（S3/R2/WebDAV等）
abstract class CloudProvider {
  /// 提供商名称 (例如: 's3', 'webdav')
  String get name;

  /// 上传配置文件
  ///
  /// [data]: JSON 字符串格式的配置数据
  /// [saveHistory]: 是否同时保存历史版本（默认 false）
  ///                当为 true 时，会额外保存一个带时间戳的文件
  ///
  /// 返回上传后的文件元数据
  Future<CloudFile> upload(String data, {bool saveHistory = false});

  /// 下载最新配置文件
  ///
  /// 返回 JSON 字符串格式的配置数据
  Future<String> download();

  /// 下载指定历史版本
  ///
  /// [version]: 版本标识（时间戳格式，如 "20251108143025"）
  ///
  /// 返回 JSON 字符串格式的配置数据
  Future<String> downloadVersion(String version);

  /// 列出所有历史版本
  ///
  /// 返回按时间倒序排列的历史版本列表（最新的在前）
  Future<List<CloudFile>> listVersions();

  /// 删除指定历史版本
  ///
  /// [version]: 版本标识（时间戳格式）
  Future<void> deleteVersion(String version);

  /// 获取最新文件的元数据（修改时间等）
  ///
  /// 如果文件不存在，返回 null
  Future<CloudFile?> getFileMetadata();

  /// 测试连接
  ///
  /// 返回 true 表示连接成功，false 表示连接失败
  Future<bool> testConnection();
}

/// 云文件元数据
class CloudFile {
  /// 版本标识
  /// - 对于历史版本：时间戳格式 (如 "20251108143025")
  /// - 对于最新版本：可能是 "latest" 或时间戳
  final String version;

  /// 文件修改时间
  final DateTime modifiedTime;

  /// 文件大小（字节）
  final int size;

  /// ETag（可选，用于缓存验证）
  final String? etag;

  CloudFile({
    required this.version,
    required this.modifiedTime,
    required this.size,
    this.etag,
  });

  /// 将时间戳转换为可读的时间字符串
  /// 例如: "20251108143025" -> "2025-11-08 14:30:25"
  String get formattedTime {
    if (version == 'latest') {
      return modifiedTime.toString();
    }

    // Parse timestamp: yyyyMMddHHmmss
    if (version.length == 14) {
      try {
        String year = version.substring(0, 4);
        String month = version.substring(4, 6);
        String day = version.substring(6, 8);
        String hour = version.substring(8, 10);
        String minute = version.substring(10, 12);
        String second = version.substring(12, 14);
        return '$year-$month-$day $hour:$minute:$second';
      } catch (e) {
        return modifiedTime.toString();
      }
    }

    return modifiedTime.toString();
  }

  /// 将文件大小转换为人类可读的格式
  /// 例如: 1024 -> "1.0 KB", 1048576 -> "1.0 MB"
  String get formattedSize {
    if (size < 1024) {
      return '$size B';
    } else if (size < 1024 * 1024) {
      return '${(size / 1024).toStringAsFixed(1)} KB';
    } else if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
  }
}
