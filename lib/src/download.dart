import "dart:async";
import "dart:io";

import "package:dio/dio.dart";
import "package:path/path.dart" as path;

/// Manages file downloads with retry logic and progress reporting.
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
      required int attempt,
      required int maxRetries,
      required String url,
      required String filePath,
      required String fullSavePath,
      void Function(double receivedKB, double totalKB)? progressCallback,
      required List<Duration> retryDelays}) async {
    if (attempt > 0) {
      await Future.delayed(retryDelays[attempt - 1]);
      print(
          "Retrying download (attempt ${attempt + 1}/$maxRetries): $filePath");
    }
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
    );

    print("File downloaded to $fullSavePath");
  }

  bool checkIsNetworkError(DioException e) {
    return e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.connectionError ||
        (e.error is SocketException) ||
        (e.message?.toLowerCase().contains('failed host lookup') ?? false) ||
        (e.message?.toLowerCase().contains('socketexception') ?? false);
  }

  /// Downloads a file with retry logic and progress reporting.
  /// [progressCallback] receives two doubles: receivedKB and totalKB.
  /// Uses Dio with automatic connection pooling and DNS caching.
  Future<void> downloadFile(
    String? host,
    String filePath,
    String savePath,
    void Function(double receivedKB, double totalKB)? progressCallback,
  ) async {
    if (host == null) return;

    final fullSavePath = path.join("$savePath/update", filePath);
    final saveDirectory = Directory(path.dirname(fullSavePath));

    if (!saveDirectory.existsSync()) {
      try {
        await saveDirectory.create(recursive: true);
        print("Created directory: ${saveDirectory.path}");
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

    final url = "$host/$filePath";
    final dio = _getDio();

    const maxRetries = 3;
    const retryDelays = [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 5)
    ];

    Exception? lastError;

    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        await _tryDownloadFile(
          dio: dio,
          attempt: attempt,
          maxRetries: maxRetries,
          url: url,
          filePath: filePath,
          fullSavePath: fullSavePath,
          progressCallback: progressCallback,
          retryDelays: retryDelays,
        );
        return;
      } on DioException catch (e) {
        final isNetworkError = checkIsNetworkError(e);

        if (isNetworkError && attempt < maxRetries - 1) {
          lastError = Exception("Network error: ${e.message}");
          continue;
        } else {
          String errorMessage = "Failed to download file: $url\n"
              "  File path: $filePath\n"
              "  Save path: $fullSavePath\n";

          if (e.response != null) {
            errorMessage += "  Status code: ${e.response!.statusCode}\n"
                "  Reason phrase: ${e.response!.statusMessage}\n";
          }

          if (e.type == DioExceptionType.connectionTimeout ||
              e.type == DioExceptionType.receiveTimeout ||
              e.type == DioExceptionType.sendTimeout) {
            errorMessage += "  Error: Timeout - ${e.message}\n";
          } else if (e.type == DioExceptionType.connectionError) {
            errorMessage += "  Error: Connection error - ${e.message}\n";
          } else {
            errorMessage += "  Error: ${e.message}\n";
          }

          if (attempt == maxRetries - 1) {
            // Add retry information when all attempts failed
            final errorWithRetries = Exception("$errorMessage"
                "  Retry attempts: $maxRetries\n"
                "  All attempts failed");
            throw errorWithRetries;
          }
          lastError = Exception(errorMessage);
        }
      } catch (e) {
        final errorString = e.toString().toLowerCase();
        final isNetworkError = errorString.contains('socketexception') ||
            errorString.contains('failed host lookup') ||
            errorString.contains('connection') ||
            errorString.contains('timeout') ||
            errorString.contains('network');

        if (isNetworkError && attempt < maxRetries - 1) {
          lastError = e is Exception ? e : Exception(e.toString());
          continue; // Retry
        } else {
          if (attempt == maxRetries - 1) {
            final baseError = e is Exception ? e.toString() : e.toString();
            final errorWithRetries = Exception("Failed to download file: $url\n"
                "  File path: $filePath\n"
                "  Save path: $fullSavePath\n"
                "  Error: $baseError\n"
                "  Retry attempts: $maxRetries\n"
                "  All attempts failed");
            throw errorWithRetries;
          }
          lastError = e is Exception ? e : Exception(e.toString());
        }
      }
    }

    final finalError = lastError ??
        Exception(
            "Failed to download file after $maxRetries attempts: $filePath");

    final errorWithRetries = Exception("${finalError.toString()}\n"
        "  Retry attempts: $maxRetries\n"
        "  All attempts failed");

    throw errorWithRetries;
  }
}
