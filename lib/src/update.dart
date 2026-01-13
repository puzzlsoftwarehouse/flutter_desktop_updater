import "dart:async";
import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/src/download.dart";
import "package:flutter/material.dart";
import "package:path/path.dart" as path;

Future<bool> _canWriteToDirectory(Directory dir) async {
  try {
    final testFile = File(path.join(dir.path, ".write_test"));
    await testFile.writeAsString("test");
    await testFile.delete();
    return true;
  } catch (e) {
    return false;
  }
}

Future<String> _getDownloadPath(Directory targetDir) async {
  if (Platform.isWindows) {
    final targetPath = targetDir.path.toLowerCase();
    final isProgramFiles = targetPath.contains("program files") ||
        targetPath.contains("program files (x86)");

    if (isProgramFiles || !await _canWriteToDirectory(targetDir)) {
      final tempDir =
          await Directory.systemTemp.createTemp("desktop_updater_download");
      return tempDir.path;
    }
  }

  if (!await _canWriteToDirectory(targetDir)) {
    final tempDir =
        await Directory.systemTemp.createTemp("desktop_updater_download");
    return tempDir.path;
  }

  return targetDir.path;
}

/// Modified updateAppFunction to return a stream of UpdateProgress.
/// The stream emits total kilobytes, received kilobytes, and the currently downloading file's name.
Future<Stream<UpdateProgress>> updateAppFunction({
  required String remoteUpdateFolder,
  required List<FileHashModel?> changes,
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

  final responseStream = StreamController<UpdateProgress>();

  try {
    if (await dir.exists()) {
      if (changes.isEmpty) {
        debugPrint("No updates required.");
        await responseStream.close();
        return responseStream.stream;
      }

      final downloadPath = await _getDownloadPath(dir);
      final useTemp = downloadPath != dir.path;

      if (useTemp) {
        debugPrint("Usando pasta temp para download: $downloadPath");
      }

      var receivedBytes = 0.0;
      final totalFiles = changes.length;
      var completedFiles = 0;

      // Calculate total length in KB
      final totalLengthKB = changes.fold<double>(
        0,
        (previousValue, element) =>
            previousValue + ((element?.length ?? 0) / 1024.0),
      );

      final changesFutureList = <Future<dynamic>>[];

      for (final file in changes) {
        if (file != null) {
          changesFutureList.add(
            downloadFile(
              remoteUpdateFolder,
              file.filePath,
              downloadPath,
              (received, total) {
                receivedBytes += received;
                responseStream.add(
                  UpdateProgress(
                    totalBytes: totalLengthKB,
                    receivedBytes: receivedBytes,
                    currentFile: file.filePath,
                    totalFiles: totalFiles,
                    completedFiles: completedFiles,
                  ),
                );
              },
            ).then((_) {
              completedFiles += 1;

              responseStream.add(
                UpdateProgress(
                  totalBytes: totalLengthKB,
                  receivedBytes: receivedBytes,
                  currentFile: file.filePath,
                  totalFiles: totalFiles,
                  completedFiles: completedFiles,
                ),
              );
              debugPrint("Completed: ${file.filePath}");
            }).catchError((error) {
              responseStream.addError(error);
              return null;
            }),
          );
        }
      }

      unawaited(
        Future.wait(changesFutureList).then((_) async {
          await responseStream.close();
        }),
      );

      return responseStream.stream;
    }
  } catch (e) {
    responseStream.addError(e);
    await responseStream.close();
  }

  return responseStream.stream;
}
