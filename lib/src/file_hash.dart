import "dart:async";
import "dart:convert";
import "dart:io";

import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/src/app_archive.dart";
import "package:flutter/material.dart";

Future<String> getFileHash(File file) async {
  try {
    // Read file content
    final List<int> fileBytes = await file.readAsBytes();

    // Compute hash with Blake2b algorithm
    final hash = await Blake2b().hash(fileBytes);

    // Encode hash to base64 and return
    return base64.encode(hash.bytes);
  } catch (e) {
    debugPrint("Error reading file ${file.path}: $e");
    return "";
  }
}

bool _pathEquals(String a, String b) {
  final na = a.replaceAll(r'\', '/');
  final nb = b.replaceAll(r'\', '/');
  if (Platform.isWindows) {
    return na.toLowerCase() == nb.toLowerCase();
  }
  return na == nb;
}

Future<List<FileHashModel?>> verifyFileHashes(
  String oldHashFilePath,
  String newHashFilePath, {
  bool returnAllOnAnyChange = false,
}) async {
  if (oldHashFilePath == newHashFilePath) {
    return [];
  }

  final oldFile = File(oldHashFilePath);
  final newFile = File(newHashFilePath);

  if (!oldFile.existsSync() || !newFile.existsSync()) {
    throw Exception("Desktop Updater: Hash files do not exist");
  }

  final oldString = await oldFile.readAsString();
  final newString = await newFile.readAsString();

  // Decode as List<FileHashModel?>
  final oldHashes = (jsonDecode(oldString) as List<dynamic>)
      .map<FileHashModel?>(
        (e) => FileHashModel.fromJson(e as Map<String, dynamic>),
      )
      .toList();
  final newHashes = (jsonDecode(newString) as List<dynamic>)
      .map<FileHashModel?>(
        (e) => FileHashModel.fromJson(e as Map<String, dynamic>),
      )
      .toList();

  final changes = <FileHashModel?>[];

  for (final newHash in newHashes) {
    final newPath = newHash?.filePath ?? "";
    final oldHash = oldHashes.firstWhere(
      (element) =>
          element?.filePath != null && _pathEquals(element!.filePath, newPath),
      orElse: () => null,
    );

    if (oldHash == null || oldHash.calculatedHash != newHash?.calculatedHash) {
      changes.add(
        FileHashModel(
          filePath: newHash?.filePath ?? "",
          calculatedHash: newHash?.calculatedHash ?? "",
          length: newHash?.length ?? 0,
        ),
      );
    }
  }

  if (returnAllOnAnyChange && changes.isNotEmpty) {
    return newHashes;
  }

  return changes;
}

// Computes hashes of all files in a directory and writes them to a file
Future<String> genFileHashes({String? path}) async {
  path ??= Platform.resolvedExecutable;

  final directoryPath =
      path.substring(0, path.lastIndexOf(Platform.pathSeparator));

  var dir = Directory(directoryPath);

  if (Platform.isMacOS) {
    dir = dir.parent;
  }

  // If the given path is a directory
  if (await dir.exists()) {
    // Create temp directory
    final tempDir = await Directory.systemTemp.createTemp("desktop_updater");

    // Create output file in temp dir
    final outputFile =
        File("${tempDir.path}${Platform.pathSeparator}hashes.json");

    // Open output file for writing
    final sink = outputFile.openWrite();

    // ignore: prefer_final_locals
    var hashList = <FileHashModel>[];

    // Iterate over all files in the directory
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        // Get file hash
        final hash = await getFileHash(entity);

        final foundPath = entity.path.substring(dir.path.length + 1);

        // Add file path and hash to list
        if (hash.isNotEmpty) {
          final hashObj = FileHashModel(
            filePath: foundPath,
            calculatedHash: hash,
            length: entity.lengthSync(),
          );
          hashList.add(hashObj);
        }
      }
    }

    // Convert file hashes to JSON format
    final jsonStr = jsonEncode(hashList);

    // Write to output file
    sink.write(jsonStr);

    // Flush and close output
    await sink.close();
    return outputFile.path;
  } else {
    throw Exception("Desktop Updater: Directory does not exist");
  }
}
