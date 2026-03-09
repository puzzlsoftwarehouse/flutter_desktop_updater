import "dart:async";
import "dart:io";

import "package:dio/dio.dart";
import "package:flutter/foundation.dart";
import "package:path/path.dart" as path;

/// Manages file downloads with progress reporting.
/// Uses a shared Dio instance for connection pooling and DNS caching.
class FileDownloader {
  static FileDownloader? _instance;
  Dio? _dio;

  FileDownloader._();

  /// Gets or creates a singleton instance of FileDownloader
  factory FileDownloader() {
    _instance ??= FileDownloader._();
    return _instance!;
  }

  /// Discards the singleton and Dio so the next download uses a new instance.
  /// Call after cancel to ensure no leftover state or connections.
  static void reset() {
    _instance?._dio = null;
    _instance = null;
  }

  /// Gets or creates a shared Dio instance for connection pooling.
  /// This reuses connections and caches DNS lookups automatically.
  Dio _getDio() {
    if (_dio != null) {
      return _dio!;
    }

    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 10),
      sendTimeout: const Duration(seconds: 30),
      followRedirects: true,
      maxRedirects: 5,
    ));

    return _dio!;
  }

  Future<void> _tryDownloadFile(
      {required Dio dio,
      required String url,
      required String fullSavePath,
      void Function(double receivedKB, double totalKB)? progressCallback,
      CancelToken? cancelToken}) async {
    await dio.download(
      url,
      fullSavePath,
      onReceiveProgress: (received, total) {
        if (progressCallback != null && total > 0) {
          final receivedKB = received / 1024;
          final totalKB = total / 1024;
          progressCallback(receivedKB, totalKB);
        }
      },
      options: Options(
        receiveTimeout: Duration(minutes: 10),
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
      cancelToken: cancelToken,
    );
  }

  bool checkIsNetworkError(DioException e) {
    if (e.type == DioExceptionType.cancel) return false;
    final msg = (e.message ?? e.error?.toString() ?? '').toLowerCase();
    return e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.unknown ||
        (e.error is SocketException) ||
        (e.error is OSError) ||
        msg.contains('failed host lookup') ||
        msg.contains('nodename nor servname') ||
        msg.contains('socketexception') ||
        msg.contains('connection') ||
        msg.contains('timeout');
  }

  bool _isNetworkErrorObject(Object? e) {
    if (e == null) return false;
    if (e is SocketException || e is OSError) return true;
    return isNetworkErrorString(e.toString());
  }

  /// Shared check for network error from an error message string.
  /// Used by download and update so the same patterns apply everywhere.
  static bool isNetworkErrorString(String message) {
    final s = message.toLowerCase();
    return s.contains('socket') ||
        s.contains('connection') ||
        s.contains('timeout') ||
        s.contains('network') ||
        s.contains('host lookup') ||
        s.contains('nodename nor servname') ||
        s.contains('refused') ||
        s.contains('reset') ||
        s.contains('websocket') ||
        s.contains('no connection') ||
        s.contains('network error');
  }

  /// Downloads a file with progress reporting.
  /// [progressCallback] receives two doubles: receivedKB and totalKB.
  /// [cancelToken] optional; when cancelled, aborts the download.
  Future<void> downloadFile(
    String? host,
    String filePath,
    String savePath,
    void Function(double receivedKB, double totalKB)? progressCallback, {
    CancelToken? cancelToken,
  }) async {
    if (host == null) return;

    final fullSavePath = path.join("$savePath/update", filePath);
    final saveDirectory = Directory(path.dirname(fullSavePath));

    if (!saveDirectory.existsSync()) {
      try {
        await saveDirectory.create(recursive: true);
        debugPrint("Created directory: ${saveDirectory.path}");
      } catch (e) {
        throw Exception("Failed to create directory for file download:\n"
            "  Directory path: ${saveDirectory.path}\n"
            "  File path: $filePath\n"
            "  Error: $e");
      }
    }

    if (!await saveDirectory.exists()) {
      throw Exception("Directory does not exist after creation attempt:\n"
          "  Directory path: ${saveDirectory.path}\n"
          "  File path: $filePath");
    }

    final pathSegments = filePath.replaceAll(r'\', '/').split('/');
    final encodedPath = pathSegments.map((s) => Uri.encodeComponent(s)).join('/');
    final url = "$host/$encodedPath";
    final dio = _getDio();

    try {
      await _tryDownloadFile(
        dio: dio,
        url: url,
        fullSavePath: fullSavePath,
        progressCallback: progressCallback,
        cancelToken: cancelToken,
      );
      return;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) rethrow;
      if (checkIsNetworkError(e)) {
        throw Exception("No connection / network error: ${e.message}\n  File: $filePath");
      }
      throw Exception("Failed to download file: $url\n  File: $filePath\n  Error: ${e.message}");
    } catch (e) {
      if (e is Exception && e.toString().contains("No connection")) rethrow;
      if (_isNetworkErrorObject(e)) {
        throw Exception("No connection / network error\n  File: $filePath\n  Error: $e");
      }
      throw Exception("Failed to download file: $url\n  File: $filePath\n  Error: $e");
    }
  }
}
