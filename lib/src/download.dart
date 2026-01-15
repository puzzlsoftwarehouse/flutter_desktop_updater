import "dart:async";
import "dart:io";

import "package:http/http.dart" as http;
import "package:path/path.dart" as path;

/// Modified downloadFile to report progress based on HTTP reception only.
/// [progressCallback] receives two doubles: receivedKB and totalKB.
/// Implements retry logic for network errors.
Future<void> downloadFile(
  String? host,
  String filePath,
  String savePath,
  void Function(double receivedKB, double totalKB)? progressCallback,
) async {
  if (host == null) return;

  const maxRetries = 3;
  const retryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5)
  ];

  Exception? lastError;

  for (int attempt = 0; attempt < maxRetries; attempt++) {
    http.Client? client;
    try {
      // Add small delay between retries (except first attempt)
      if (attempt > 0) {
        await Future.delayed(retryDelays[attempt - 1]);
        print(
            "Retrying download (attempt ${attempt + 1}/$maxRetries): $filePath");
      }

      client = http.Client();
      final url = "$host/$filePath";
      final request = http.Request("GET", Uri.parse(url));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        client.close();
        throw HttpException("Failed to download file: $url\n"
            "  Status code: ${response.statusCode}\n"
            "  Reason phrase: ${response.reasonPhrase}\n"
            "  File path: $filePath\n"
            "  Save path: $savePath");
      }

      // Create full save path including directories
      final fullSavePath = path.join("$savePath/update", filePath);
      final saveDirectory = Directory(path.dirname(fullSavePath));

      // Create all necessary directories
      if (!saveDirectory.existsSync()) {
        try {
          await saveDirectory.create(recursive: true);
          print("Created directory: ${saveDirectory.path}");
        } catch (e) {
          client.close();
          throw Exception("Failed to create directory for file download:\n"
              "  Directory path: ${saveDirectory.path}\n"
              "  File path: $filePath\n"
              "  Error: $e");
        }
      }

      // Check if directory is writable
      if (!await saveDirectory.exists()) {
        client.close();
        throw Exception("Directory does not exist after creation attempt:\n"
            "  Directory path: ${saveDirectory.path}\n"
            "  File path: $filePath");
      }

      // Prepare file for writing
      final file = File(fullSavePath);
      final sink = file.openWrite();
      var received = 0;
      final contentLength = response.contentLength ?? 0;

      // Listen to the HTTP response stream with timeout protection
      try {
        await response.stream
            .listen(
              (List<int> chunk) {
                // Write chunk to file
                sink.add(chunk);

                // Track received bytes for this file (used for error reporting)
                received = chunk.length;

                // Report progress
                if (progressCallback != null && contentLength != 0) {
                  final receivedKB = received / 1024;
                  final totalKB = contentLength / 1024;
                  progressCallback(receivedKB, totalKB);
                }
              },
              onDone: () async {
                await sink.close();
                client?.close();
                print("File downloaded to $fullSavePath");
              },
              onError: (e) {
                sink.close();
                client?.close();
                throw Exception("Error while downloading file:\n"
                    "  URL: $url\n"
                    "  File path: $filePath\n"
                    "  Save path: $fullSavePath\n"
                    "  Received bytes: $received / $contentLength\n"
                    "  Error: $e");
              },
              cancelOnError: true,
            )
            .asFuture()
            .timeout(
              Duration(minutes: 10), // 10 minute timeout per file
              onTimeout: () {
                sink.close();
                client?.close();
                throw TimeoutException(
                  "Download timeout after 10 minutes",
                  Duration(minutes: 10),
                );
              },
            );

        // Success! Exit retry loop
        return;
      } catch (e) {
        // Ensure resources are cleaned up on error
        try {
          sink.close();
        } catch (_) {}
        try {
          client.close();
        } catch (_) {}

        // Re-throw to be handled by outer catch
        rethrow;
      }
    } catch (e) {
      // Ensure client is closed on error
      try {
        client?.close();
      } catch (_) {}

      // Check if this is a retryable network error
      final errorString = e.toString().toLowerCase();
      final isNetworkError = errorString.contains('socketexception') ||
          errorString.contains('failed host lookup') ||
          errorString.contains('connection') ||
          errorString.contains('timeout') ||
          errorString.contains('network') ||
          errorString.contains('clientexception');

      if (isNetworkError && attempt < maxRetries - 1) {
        lastError = e is Exception ? e : Exception(e.toString());
        continue; // Retry
      } else {
        // Non-network error or max retries reached
        if (attempt == maxRetries - 1) {
          // Last attempt failed, throw the error
          throw e is Exception ? e : Exception(e.toString());
        }
        lastError = e is Exception ? e : Exception(e.toString());
      }
    }
  }

  // All retries exhausted
  throw lastError ??
      Exception(
          "Failed to download file after $maxRetries attempts: $filePath");
}
