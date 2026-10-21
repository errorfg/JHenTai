/// A test build: an app of its own beside the release one (another package
/// name and bundle id, see android/app/build.gradle and the packaging of test
/// builds), syncing only with a test bucket and a test sync server. What it
/// syncs with is given when it is built, from a file:
/// `flutter build ... --dart-define-from-file=<file>` with the keys below.
class TestBuild {
  static const bool on = bool.fromEnvironment('JH_TEST_BUILD');

  static const String s3Endpoint = String.fromEnvironment('JH_TEST_S3_ENDPOINT');
  static const String s3Bucket = String.fromEnvironment('JH_TEST_S3_BUCKET');
  static const String s3AccessKey = String.fromEnvironment('JH_TEST_S3_ACCESS_KEY');
  static const String s3SecretKey = String.fromEnvironment('JH_TEST_S3_SECRET_KEY');
  static const String serverUrl = String.fromEnvironment('JH_TEST_SERVER_URL');
  static const String serverToken = String.fromEnvironment('JH_TEST_SERVER_TOKEN');

  /// Whether a test build may sync through [provider] ('s3' or 'server')
  /// with the bucket [bucket] or the sync server at [serverUrl]: only those
  /// named as test ones, so that no setting, imported or synced, can point
  /// it at the bucket or server in use.
  static bool allows({required String provider, required String bucket, required String serverUrl}) => switch (provider) {
        's3' => bucket.endsWith('-dev'),
        'server' => Uri.tryParse(serverUrl)?.host.contains('-dev') ?? false,
        _ => false,
      };
}
