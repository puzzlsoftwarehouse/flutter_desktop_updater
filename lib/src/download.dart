import "dart:io";

import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:path/path.dart" as path;

/// Modified downloadFile to report progress based on HTTP reception only.
/// [progressCallback] receives two doubles: receivedKB and totalKB.
Future<void> downloadFile(
  String? host,
  String filePath,
  String savePath,
  void Function(double receivedKB, double totalKB)? progressCallback,
) async {
  if (host == null) return;

  final client = http.Client();
  final url = "$host/$filePath";
  final request = http.Request("GET", Uri.parse(url));
  final response = await client.send(request);

  if (response.statusCode != 200) {
    client.close();
    throw HttpException("Failed to download file: $url");
  }

  // Create full save path including directories
  final fullSavePath = path.join("$savePath/update", filePath);
  final saveDirectory = Directory(path.dirname(fullSavePath));

  // Create all necessary directories
  if (!saveDirectory.existsSync()) {
    await saveDirectory.create(recursive: true);
  }

  // Prepare file for writing
  final file = File(fullSavePath);
  final sink = file.openWrite();
  var received = 0;
  final contentLength = response.contentLength ?? 0;

  // Listen to the HTTP response stream
  await response.stream.listen(
    (List<int> chunk) {
      // Write chunk to file
      sink.add(chunk);

      // Increment received bytes based on HTTP chunk
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
      client.close();
      debugPrint("File downloaded to $fullSavePath");
    },
    onError: (e) {
      sink.close();
      client.close();
      throw e;
    },
    cancelOnError: true,
  ).asFuture();
}
