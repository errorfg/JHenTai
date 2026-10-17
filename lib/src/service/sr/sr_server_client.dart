import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';

import 'sr_tools.dart';

/// What an upscaling service says about itself.
class SrServerInfo {
  const SrServerInfo({required this.gpus, required this.maxPages, required this.availableModels});

  /// As the programs list them, e.g. `0: NVIDIA GeForce RTX 4080`.
  final List<String> gpus;

  /// Pages it takes in one request.
  final int maxPages;

  /// Ids of the models it can run.
  final Set<String> availableModels;
}

/// The upscaling service of `sr_server/` in this repository, on a computer
/// with a GPU: the same programs and models as on a desktop, so a model
/// chosen here upscales the same way.
///
/// `GET /v1/models`; `POST /v1/upscale?model=&scale=&denoise=` with a ZIP of
/// the pages of a batch, each entry named by its place in the batch,
/// answered with a ZIP of the pages upscaled (JPEG) under the same names.
class SrServerClient {
  SrServerClient(String url, {Dio? dio})
      : url = normalizeUrl(url),
        _dio = dio ??
            Dio(
              BaseOptions(
                // The first connection over a Tailscale network can take
                // about ten seconds to set up.
                connectTimeout: const Duration(seconds: 20),
                sendTimeout: const Duration(seconds: 60),
                // A batch waits for the batches of other devices.
                receiveTimeout: const Duration(seconds: 180),
              ),
            );

  final String url;
  final Dio _dio;

  /// Without spaces around or slashes at the end.
  static String normalizeUrl(String url) => url.trim().replaceFirst(RegExp(r'/+$'), '');

  Future<SrServerInfo> info() async {
    final Response<dynamic> response = await _dio.get<dynamic>(
      '$url/v1/models',
      options: Options(responseType: ResponseType.json, validateStatus: (_) => true),
    );
    final dynamic data = response.data;
    if (response.statusCode != 200 || data is! Map) {
      throw SrServerException(response.statusCode ?? 0, _messageOf(data));
    }
    return SrServerInfo(
      gpus: <String>[for (final dynamic gpu in data['gpus'] as List? ?? const <dynamic>[]) '$gpu'],
      maxPages: data['maxPages'] as int? ?? 0,
      availableModels: <String>{
        for (final dynamic model in data['models'] as List? ?? const <dynamic>[])
          if (model is Map && model['available'] == true) '${model['id']}',
      },
    );
  }

  /// Upscales the encoded [pages] of a batch (null: a page not sent) with
  /// [config]; completes with the upscaled pages, encoded, in the same
  /// places, null where the service has none (it could not read the page).
  /// Throws [SrServerException] when the service refuses the batch, and a
  /// [DioException] when it cannot be reached.
  Future<List<Uint8List?>> upscale(SrConfig config, List<Uint8List?> pages) async {
    final Archive batch = Archive();
    for (int i = 0; i < pages.length; i++) {
      final Uint8List? page = pages[i];
      if (page != null) {
        batch.addFile(ArchiveFile.noCompress('$i', page.length, page));
      }
    }
    final Uint8List body = Uint8List.fromList(ZipEncoder().encode(batch, level: Deflate.NO_COMPRESSION)!);

    final Response<List<int>> response = await _dio.post<List<int>>(
      '$url/v1/upscale',
      queryParameters: <String, dynamic>{
        'model': config.model.id,
        'scale': config.scale,
        'denoise': config.denoise,
      },
      data: Stream<List<int>>.value(body),
      options: Options(
        contentType: 'application/zip',
        headers: <String, dynamic>{Headers.contentLengthHeader: body.length},
        responseType: ResponseType.bytes,
        validateStatus: (_) => true,
      ),
    );
    final List<int> data = response.data ?? const <int>[];
    if (response.statusCode != 200) {
      dynamic error;
      try {
        error = jsonDecode(utf8.decode(data));
      } on FormatException {
        error = null;
      }
      throw SrServerException(response.statusCode ?? 0, _messageOf(error));
    }

    final List<Uint8List?> results = List<Uint8List?>.filled(pages.length, null);
    for (final ArchiveFile file in ZipDecoder().decodeBytes(data)) {
      final int? i = int.tryParse(file.name);
      if (file.isFile && i != null && i >= 0 && i < pages.length && pages[i] != null) {
        results[i] = Uint8List.fromList(file.content as List<int>);
      }
    }
    return results;
  }

  static String _messageOf(dynamic data) => data is Map && data['error'] != null ? '${data['error']}' : 'no answer';
}

class SrServerException implements Exception {
  SrServerException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'SrServerException($statusCode): $message';
}
