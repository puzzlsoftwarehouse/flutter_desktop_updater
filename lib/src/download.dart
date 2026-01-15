import "dart:async";
import "dart:io";

import "package:dio/dio.dart";
import "package:path/path.dart" as path;

// Shared Dio instance for connection pooling and DNS caching
Dio? _sharedDio;

/// Gets or creates a shared Dio instance for connection pooling
/// This reuses connections and caches DNS lookups automatically
Dio _getSharedDio() {
  if (_sharedDio != null) {
    return _sharedDio!;
  }

  _sharedDio = Dio(BaseOptions(
    connectTimeout: Duration(seconds: 30),
    receiveTimeout: Duration(minutes: 10),
    sendTimeout: Duration(seconds: 30),
    // Enable connection pooling (default in Dio)
    followRedirects: true,
    maxRedirects: 5,
  ));

  return _sharedDio!;
}

/// Modified downloadFile to report progress based on HTTP reception only.
/// [progressCallback] receives two doubles: receivedKB and totalKB.
/// Uses Dio with automatic connection pooling and DNS caching.
Future<void> downloadFile(
  String? host,
  String filePath,
  String savePath,
  void Function(double receivedKB, double totalKB)? progressCallback,
) async {
  if (host == null) return;

  // Create full save path including directories
  final fullSavePath = path.join("$savePath/update", filePath);
  final saveDirectory = Directory(path.dirname(fullSavePath));

  // Create all necessary directories
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

  // Check if directory is writable
  if (!await saveDirectory.exists()) {
    throw Exception("Directory does not exist after creation attempt:\n"
        "  Directory path: ${saveDirectory.path}\n"
        "  File path: $filePath");
  }

  final url = "$host/$filePath";
  final dio = _getSharedDio();

  const maxRetries = 3;
  const retryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5)
  ];

  Exception? lastError;

  for (int attempt = 0; attempt < maxRetries; attempt++) {
    try {
      // Add small delay between retries (except first attempt)
      if (attempt > 0) {
        await Future.delayed(retryDelays[attempt - 1]);
        print(
            "Retrying download (attempt ${attempt + 1}/$maxRetries): $filePath");
      }

      // Use Dio's download method with progress callback
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
          validateStatus: (status) => status != null && status >= 200 && status < 300,
        ),
      );

      print("File downloaded to $fullSavePath");
      return; // Success!
    } on DioException catch (e) {
      // Check if this is a retryable network error
      final isNetworkError = e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.connectionError ||
          (e.error is SocketException) ||
          (e.message?.toLowerCase().contains('failed host lookup') ?? false) ||
          (e.message?.toLowerCase().contains('socketexception') ?? false);

      if (isNetworkError && attempt < maxRetries - 1) {
        lastError = Exception("Network error: ${e.message}");
        continue; // Retry
      } else {
        // Non-network error or max retries reached
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
          final errorWithRetries = Exception(
            "$errorMessage"
            "  Retry attempts: $maxRetries\n"
            "  All attempts failed"
          );
          throw errorWithRetries;
        }
        lastError = Exception(errorMessage);
      }
    } catch (e) {
      // Handle other errors
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
          // Add retry information when all attempts failed
          final baseError = e is Exception ? e.toString() : e.toString();
          final errorWithRetries = Exception(
            "Failed to download file: $url\n"
            "  File path: $filePath\n"
            "  Save path: $fullSavePath\n"
            "  Error: $baseError\n"
            "  Retry attempts: $maxRetries\n"
            "  All attempts failed"
          );
          throw errorWithRetries;
        }
        lastError = e is Exception ? e : Exception(e.toString());
      }
    }
  }

  // All retries exhausted - include retry information in error
  final finalError = lastError ??
      Exception(
          "Failed to download file after $maxRetries attempts: $filePath");
  
  // Add retry information to error message
  final errorWithRetries = Exception(
    "${finalError.toString()}\n"
    "  Retry attempts: $maxRetries\n"
    "  All attempts failed"
  );
  
  throw errorWithRetries;
}
