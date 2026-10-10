/// saver_gallery as seen by HarmonyOS builds: the API of 5.1.0 that the app
/// uses, answering that saving is not available. See pubspec.yaml.
library saver_gallery;

import 'dart:typed_data';

class SaveResult {
  const SaveResult(this.isSuccess, this.errorMessage, {this.savedUri, List<String>? savedUris})
      : savedUris = savedUris ?? const <String>[];

  final bool isSuccess;
  final String? errorMessage;
  final String? savedUri;
  final List<String> savedUris;

  @override
  String toString() => 'SaveResult(isSuccess: $isSuccess, errorMessage: $errorMessage)';
}

class SaverGallery {
  static const SaveResult _unavailable = SaveResult(false, 'Saving to the gallery is not available on HarmonyOS yet');

  static Future<SaveResult> saveImage(
    Uint8List imageBytes, {
    int quality = 100,
    String? extension,
    required String fileName,
    String? albumPath,
    required bool skipIfExists,
  }) async =>
      _unavailable;

  static Future<SaveResult> saveFile({
    required String filePath,
    required String fileName,
    String? albumPath,
    required bool skipIfExists,
  }) async =>
      _unavailable;
}
