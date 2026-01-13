import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/src/app_archive.dart";
import "package:desktop_updater/src/file_hash.dart";
import "package:flutter/material.dart";
import "package:http/http.dart" as http;

Future<List<FileHashModel?>> prepareUpdateAppFunction({
  required String remoteUpdateFolder,
}) async {
  final executablePath = Platform.resolvedExecutable;

  final directoryPath = executablePath.substring(
    0,
    executablePath.lastIndexOf(Platform.pathSeparator),
  );

  var dir = Directory(directoryPath);

  if (Platform.isMacOS) {
    dir = dir.parent;
  }

  // Eğer belirtilen yol bir dizinse
  if (await dir.exists()) {
    // temp dizini oluşturulur
    final tempDir = await Directory.systemTemp.createTemp("desktop_updater");

    // Download oldHashFilePath
    final client = http.Client();

    final newHashFileUrl = "$remoteUpdateFolder/hashes.json";
    final newHashFileRequest = http.Request("GET", Uri.parse(newHashFileUrl));
    final newHashFileResponse = await client.send(newHashFileRequest);

    // temp dizinindeki dosyaları kopyala
    // dir + output.txt dosyası oluşturulur
    final outputFile =
        File("${tempDir.path}${Platform.pathSeparator}hashes.json");

    // Çıktı dosyasını açıyoruz
    final sink = outputFile.openWrite();

    // Save the file
    await newHashFileResponse.stream.pipe(sink);

    // Close the file
    await sink.close();

    debugPrint("Hashes file downloaded to ${outputFile.path}");

    final oldHashFilePath = await genFileHashes();
    final newHashFilePath = outputFile.path;

    debugPrint("Old hashes file: $oldHashFilePath");

    final changes = await verifyFileHashes(
      oldHashFilePath,
      newHashFilePath,
    );

    return changes;
  }
  return [];
}
