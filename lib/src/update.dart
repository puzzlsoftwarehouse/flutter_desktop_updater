import "dart:async";
import "dart:io";

import "package:desktop_updater/src/app_archive.dart";
import "package:desktop_updater/src/download.dart";
import "package:desktop_updater/src/update_progress.dart";
import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:path/path.dart" as path;

class DownloadCompleteResult {
  const DownloadCompleteResult({
    required this.successCount,
    required this.failedCount,
    required this.failedFilePaths,
    required this.cancelled,
    required this.hadNetworkError,
    required this.networkErrorFilePaths,
  });

  final int successCount;
  final int failedCount;
  final List<String> failedFilePaths;
  final bool cancelled;
  final bool hadNetworkError;
  final List<String> networkErrorFilePaths;

  bool get hasFailures => failedCount > 0;
  bool get hasNetworkFailures =>
      hadNetworkError && networkErrorFilePaths.isNotEmpty;
}

class UpdateStreamResult {
  UpdateStreamResult({
    required this.stream,
    required this.cancel,
    required this.whenComplete,
  });
  final Stream<UpdateProgress> stream;
  final void Function() cancel;
  final Future<DownloadCompleteResult> whenComplete;
}

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

/// Modified updateAppFunction to return a stream of UpdateProgress and a cancel callback.
Future<UpdateStreamResult> updateAppFunction({
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
  final activeCancelTokens = <CancelToken>[];
  final completeCompleter = Completer<DownloadCompleteResult>();
  var cancelled = false;
  Timer? summaryTimer;
  Timer? periodicLogTimer;

  void cancelDownloads() {
    if (cancelled) return;
    cancelled = true;
    summaryTimer?.cancel();
    summaryTimer = null;
    periodicLogTimer?.cancel();
    periodicLogTimer = null;
    for (final token in List<CancelToken>.from(activeCancelTokens)) {
      token.cancel("Download cancelled");
    }
    if (!completeCompleter.isCompleted) {
      completeCompleter.complete(DownloadCompleteResult(
        successCount: 0,
        failedCount: 0,
        failedFilePaths: [],
        cancelled: true,
        hadNetworkError: false,
        networkErrorFilePaths: [],
      ));
    }
    if (!responseStream.isClosed) {
      responseStream.close();
    }
    FileDownloader.reset();
  }

  final result = UpdateStreamResult(
    stream: responseStream.stream,
    cancel: cancelDownloads,
    whenComplete: completeCompleter.future,
  );

  try {
    if (await dir.exists()) {
      if (changes.isEmpty) {
        debugPrint("No updates required.");
        if (!completeCompleter.isCompleted) {
          completeCompleter.complete(const DownloadCompleteResult(
            successCount: 0,
            failedCount: 0,
            failedFilePaths: [],
            cancelled: false,
            hadNetworkError: false,
            networkErrorFilePaths: [],
          ));
        }
        await responseStream.close();
        return result;
      }

      String downloadPath;
      Directory updateFolder;
      if (Platform.isMacOS) {
        final home = Platform.environment['HOME'];
        final bundleId = await _getBundleIdFromInfoPlist();
        if (home != null && bundleId != null) {
          downloadPath = path.join(
            home,
            "Library",
            "Application Support",
            bundleId,
            "updates",
          );
          updateFolder = Directory(path.join(downloadPath, "update"));
          if (await updateFolder.exists()) {
            await updateFolder.delete(recursive: true);
          }
          await updateFolder.create(recursive: true);
        } else {
          downloadPath = await _getDownloadPath(dir);
          updateFolder = Directory(path.join(downloadPath, "update"));
        }
      } else {
        downloadPath = await _getDownloadPath(dir);
        updateFolder = Directory(path.join(downloadPath, "update"));
      }
      final useTemp = downloadPath != dir.path;

      if (useTemp) {
        debugPrint("Using temp folder for download: $downloadPath");
      }

      var receivedBytes = 0.0;
      final totalFiles = changes.length;
      var completedFiles = 0;

      final totalLengthKB = changes.fold<double>(
        0,
        (previousValue, element) =>
            previousValue + ((element?.length ?? 0) / 1024.0),
      );

      final downloadResults = <Map<String, dynamic>>[];

      final fileProgress = <String, double>{};

      const maxConcurrentDownloads = 64;
      final activeDownloads = <Completer<void>>[];
      final downloadQueue = <FileHashModel>[];

      for (final file in changes) {
        if (file != null) {
          downloadQueue.add(file);
        }
      }
      downloadQueue.sort((a, b) => b.length.compareTo(a.length));

      final dirsToCreate = <String>{};
      for (final file in downloadQueue) {
        dirsToCreate.add(
            path.dirname(path.join(downloadPath, "update", file.filePath)));
      }
      for (final dirPath in dirsToCreate) {
        final d = Directory(dirPath);
        if (!await d.exists()) {
          await d.create(recursive: true);
        }
      }

      var lastProgressEmit = DateTime.now();
      const progressThrottleMs = 80;

      unawaited(
        () async {
          try {
            final downloadStartTime = DateTime.now();
            Directory? logDir;
            String? logFileName;
            const summaryInterval = Duration(seconds: 5);

            void printSummary() {
              if (cancelled) return;
              final ok =
                  downloadResults.where((r) => r["status"] == "success").length;
              final failed =
                  downloadResults.where((r) => r["status"] == "failed").length;
              final pct =
                  totalFiles > 0 ? (ok + failed) / totalFiles * 100 : 0.0;
              final receivedMb = (receivedBytes * 1024).toInt();
              final totalMb = (totalLengthKB * 1024).toInt();
              print(
                "[Update] $ok/$totalFiles files (${pct.toStringAsFixed(0)}%), "
                "$failed failed, ${_formatBytes(receivedMb)} / ${_formatBytes(totalMb)}");
            }

            summaryTimer = Timer.periodic(summaryInterval, (_) {
              if (cancelled || responseStream.isClosed) return;
              printSummary();
            });

            if (Platform.isMacOS) {
              final appSupportDir = Platform.environment['HOME'];
              if (appSupportDir != null) {
                final bundleId = await _getBundleIdFromInfoPlist();
                if (bundleId != null) {
                  logDir = Directory(
                    path.join(
                      appSupportDir,
                      "Library",
                      "Application Support",
                      bundleId,
                      "logs",
                    ),
                  );
                  if (!await logDir.exists()) {
                    await logDir.create(recursive: true);
                  }
                }
              }
            }
            if (logDir == null || !await logDir.exists()) {
              logDir = updateFolder;
            }

            final timestamp = DateTime.now();
            logFileName = "download_${timestamp.millisecondsSinceEpoch}.log";

            // Create initial log file
            try {
              final logFile = File(path.join(logDir.path, logFileName));
              final initialSink = logFile.openWrite()
                ..writeln("=" * 80)
                ..writeln("DOWNLOAD LOG - ${timestamp.toIso8601String()}")
                ..writeln("=" * 80)
                ..writeln("")
                ..writeln("INITIAL STATUS:")
                ..writeln("  Remote folder: $remoteUpdateFolder")
                ..writeln("  Update folder: ${updateFolder.path}")
                ..writeln("  Total files: $totalFiles")
                ..writeln(
                    "  Total size: ${_formatBytes((totalLengthKB * 1024).toInt())}")
                ..writeln("  Started at: ${timestamp.toIso8601String()}")
                ..writeln("")
                ..writeln(
                    "Periodic updates will be appended every 10 seconds...")
                ..writeln("");
              await initialSink.close();
              debugPrint("Download log: ${logFile.path}");
            } catch (e) {
              debugPrint("Warning: Could not create initial log file: $e");
            }

            Future<void> savePeriodicLog() async {
              if (cancelled) return;
              try {
                await _saveDownloadLogPeriodic(
                  logDir: logDir!,
                  logFileName: logFileName!,
                  updateFolder: updateFolder,
                  downloadResults: downloadResults,
                  remoteUpdateFolder: remoteUpdateFolder,
                  totalFiles: totalFiles,
                  receivedBytes: receivedBytes,
                  totalLengthKB: totalLengthKB,
                  getCancelled: () => cancelled,
                );
              } catch (e) {
                if (!cancelled) debugPrint("Error saving periodic log: $e");
              }
            }

            // Start periodic log saving every 10 seconds
            periodicLogTimer = Timer.periodic(Duration(seconds: 10), (_) {
              if (cancelled) return;
              unawaited(savePeriodicLog());
            });

            while (downloadQueue.isNotEmpty || activeDownloads.isNotEmpty) {
              if (cancelled) break;

              while (activeDownloads.length < maxConcurrentDownloads &&
                  downloadQueue.isNotEmpty &&
                  !cancelled) {
                final file = downloadQueue.removeAt(0);
                final startTime = DateTime.now();
                final cancelToken = CancelToken();
                activeCancelTokens.add(cancelToken);

                final completer = Completer<void>();
                activeDownloads.add(completer);

                fileProgress[file.filePath] = 0.0;

                final downloader = FileDownloader();
                downloader.downloadFile(
                  remoteUpdateFolder,
                  file.filePath,
                  downloadPath,
                  (received, total) {
                    try {
                      if (cancelled || responseStream.isClosed) return;
                      final lastReceived = fileProgress[file.filePath] ?? 0.0;
                      final increment = received - lastReceived;
                      if (increment > 0) {
                        receivedBytes += increment;
                        fileProgress[file.filePath] = received;
                      }
                      final now = DateTime.now();
                      if (now.difference(lastProgressEmit).inMilliseconds >=
                          progressThrottleMs) {
                        lastProgressEmit = now;
                        if (!cancelled && !responseStream.isClosed) {
                          responseStream.add(
                            UpdateProgress(
                              totalBytes: totalLengthKB,
                              receivedBytes: receivedBytes,
                              currentFile: file.filePath,
                              totalFiles: totalFiles,
                              completedFiles: completedFiles,
                            ),
                          );
                        }
                      }
                    } catch (_) {}
                  },
                  cancelToken: cancelToken,
                ).then((_) async {
                  if (cancelled) {
                    activeCancelTokens.remove(cancelToken);
                    activeDownloads.remove(completer);
                    if (!completer.isCompleted) completer.complete();
                    return;
                  }
                  try {
                    completedFiles += 1;

                    final fileSizeKB = file.length / 1024.0;
                    final lastReported = fileProgress[file.filePath] ?? 0.0;
                    final remaining = fileSizeKB - lastReported;

                    if (remaining > 0) {
                      receivedBytes += remaining;
                      fileProgress[file.filePath] = fileSizeKB;
                    }

                    final endTime = DateTime.now();
                    final duration = endTime.difference(startTime);

                    final fullPath =
                        path.join(updateFolder.path, file.filePath);
                    final downloadedFile = File(fullPath);
                    int fileSize = 0;
                    bool fileExists = false;

                    try {
                      if (await downloadedFile.exists()) {
                        fileExists = true;
                        fileSize = await downloadedFile.length();
                      }
                    } catch (e) {
                      // Ignore errors getting file size
                    }

                    downloadResults.add({
                      "file": file.filePath,
                      "status": "success",
                      "size": fileSize,
                      "expectedSize": file.length,
                      "duration": duration.inMilliseconds,
                      "startTime": startTime.toIso8601String(),
                      "endTime": endTime.toIso8601String(),
                      "exists": fileExists,
                    });

                    if (!cancelled && !responseStream.isClosed) {
                      responseStream.add(
                        UpdateProgress(
                          totalBytes: totalLengthKB,
                          receivedBytes: receivedBytes,
                          currentFile: file.filePath,
                          totalFiles: totalFiles,
                          completedFiles: completedFiles,
                        ),
                      );
                    }
                  } finally {
                    activeCancelTokens.remove(cancelToken);
                    activeDownloads.remove(completer);
                    if (!completer.isCompleted) {
                      completer.complete();
                    }
                  }
                }).catchError((error, stackTrace) {
                  if (cancelled) {
                    activeCancelTokens.remove(cancelToken);
                    activeDownloads.remove(completer);
                    if (!completer.isCompleted) completer.complete();
                    return;
                  }
                  final endTime = DateTime.now();
                  final duration = endTime.difference(startTime);
                  final isNetwork = FileDownloader.isNetworkErrorString(error.toString());

                  downloadResults.add({
                    "file": file.filePath,
                    "status": "failed",
                    "size": 0,
                    "expectedSize": file.length,
                    "duration": duration.inMilliseconds,
                    "startTime": startTime.toIso8601String(),
                    "endTime": endTime.toIso8601String(),
                    "error": error.toString(),
                    "exists": false,
                    "networkError": isNetwork,
                  });

                  if (isNetwork) {
                    cancelled = true;
                    summaryTimer?.cancel();
                    summaryTimer = null;
                    periodicLogTimer?.cancel();
                    periodicLogTimer = null;
                    for (final t
                        in List<CancelToken>.from(activeCancelTokens)) {
                      t.cancel("Network error");
                    }
                    if (!completeCompleter.isCompleted) {
                      final ok = downloadResults
                          .where((r) => r["status"] == "success")
                          .length;
                      final failed = downloadResults
                          .where((r) => r["status"] == "failed")
                          .length;
                      final failedPaths = downloadResults
                          .where((r) => r["status"] == "failed")
                          .map<String>((r) => r["file"] as String)
                          .toList();
                      final networkPaths = downloadResults
                          .where((r) =>
                              r["status"] == "failed" &&
                              (r["networkError"] == true))
                          .map<String>((r) => r["file"] as String)
                          .toList();
                      completeCompleter.complete(DownloadCompleteResult(
                        successCount: ok,
                        failedCount: failed,
                        failedFilePaths: failedPaths,
                        cancelled: false,
                        hadNetworkError: true,
                        networkErrorFilePaths: networkPaths,
                      ));
                    }
                    if (!responseStream.isClosed) {
                      responseStream.addError(
                        Exception(
                            "No connection / network error. Download aborted.\n  $error"),
                        stackTrace,
                      );
                      responseStream.close();
                    }
                    FileDownloader.reset();
                  } else if (!responseStream.isClosed) {
                    responseStream.addError(
                      Exception("Failed to download update file:\n"
                          "  File: ${file.filePath}\n"
                          "  Remote folder: $remoteUpdateFolder\n"
                          "  Error: $error"),
                      stackTrace,
                    );
                  }

                  activeCancelTokens.remove(cancelToken);
                  activeDownloads.remove(completer);
                  if (!completer.isCompleted) {
                    completer.complete();
                  }
                });
              }

              if (activeDownloads.isNotEmpty) {
                final futures = activeDownloads.map((c) => c.future).toList();
                if (futures.isNotEmpty) {
                  await Future.any(futures);
                }
                await Future.delayed(Duration.zero);
              } else if (downloadQueue.isNotEmpty) {
                await Future.delayed(Duration(milliseconds: 50));
              } else {
                break;
              }
            }

            summaryTimer?.cancel();
            summaryTimer = null;
            periodicLogTimer?.cancel();
            periodicLogTimer = null;

            final ok =
                downloadResults.where((r) => r["status"] == "success").length;
            final failed =
                downloadResults.where((r) => r["status"] == "failed").length;
            final failedPaths = downloadResults
                .where((r) => r["status"] == "failed")
                .map<String>((r) => r["file"] as String)
                .toList();
            final networkErrorPaths = downloadResults
                .where((r) =>
                    r["status"] == "failed" && (r["networkError"] == true))
                .map<String>((r) => r["file"] as String)
                .toList();

            if (!completeCompleter.isCompleted) {
              completeCompleter.complete(DownloadCompleteResult(
                successCount: ok,
                failedCount: failed,
                failedFilePaths: failedPaths,
                cancelled: cancelled,
                hadNetworkError: networkErrorPaths.isNotEmpty,
                networkErrorFilePaths: networkErrorPaths,
              ));
            }

            if (!cancelled) {
              final elapsed = DateTime.now().difference(downloadStartTime);
              final totalMb = (totalLengthKB * 1024).toInt();
              print("[Update] Completed: $ok success, $failed failed, "
                  "${_formatBytes(totalMb)} in ${_formatDuration(elapsed)}");
              if (failed > 0) {
                print("[Update] Failure details at: ${logDir.path}");
              }
              await _saveDownloadLog(
                updateFolder: updateFolder,
                downloadResults: downloadResults,
                remoteUpdateFolder: remoteUpdateFolder,
                totalFiles: totalFiles,
              );
            }

            if (!responseStream.isClosed) {
              await responseStream.close();
            }
          } catch (e, st) {
            if (cancelled) return;
            if (!completeCompleter.isCompleted) {
              completeCompleter.complete(DownloadCompleteResult(
                successCount: 0,
                failedCount: 0,
                failedFilePaths: [],
                cancelled: false,
                hadNetworkError: FileDownloader.isNetworkErrorString(e.toString()),
                networkErrorFilePaths: [],
              ));
            }
            if (!responseStream.isClosed) {
              responseStream.addError(Exception("Update error: $e"), st);
              responseStream.close();
            }
            summaryTimer?.cancel();
            summaryTimer = null;
            periodicLogTimer?.cancel();
            periodicLogTimer = null;
            FileDownloader.reset();
          }
        }(),
      );

      return result;
    }
  } catch (e, stackTrace) {
    if (!completeCompleter.isCompleted) {
      completeCompleter.complete(DownloadCompleteResult(
        successCount: 0,
        failedCount: 0,
        failedFilePaths: [],
        cancelled: true,
        hadNetworkError: FileDownloader.isNetworkErrorString(e.toString()),
        networkErrorFilePaths: [],
      ));
    }
    if (!responseStream.isClosed) {
      responseStream.addError(
        Exception("Failed to initialize update process:\n"
            "  Directory: ${dir.path}\n"
            "  Remote folder: $remoteUpdateFolder\n"
            "  Files to update: ${changes.length}\n"
            "  Error: $e"),
        stackTrace,
      );
      await responseStream.close();
    }
  }

  return result;
}

/// Saves a periodic snapshot of the download progress (called every 10 seconds)
Future<void> _saveDownloadLogPeriodic({
  required Directory logDir,
  required String logFileName,
  required Directory updateFolder,
  required List<Map<String, dynamic>> downloadResults,
  required String remoteUpdateFolder,
  required int totalFiles,
  required double receivedBytes,
  required double totalLengthKB,
  bool Function()? getCancelled,
}) async {
  if (getCancelled?.call() ?? false) return;
  try {
    final timestamp = DateTime.now();
    final logFile = File(path.join(logDir.path, logFileName));

    final sink = logFile.openWrite(mode: FileMode.append);

    sink.writeln("");
    sink.writeln("=" * 80);
    sink.writeln("PERIODIC UPDATE - ${timestamp.toIso8601String()}");
    sink.writeln("=" * 80);
    sink.writeln("");

    final successful =
        downloadResults.where((r) => r["status"] == "success").length;
    final failed = downloadResults.where((r) => r["status"] == "failed").length;
    final inProgress = totalFiles - successful - failed;
    final totalSize = downloadResults.fold<int>(
      0,
      (sum, r) => sum + (r["size"] as int? ?? 0),
    );
    final progressPercent = totalLengthKB > 0
        ? (receivedBytes / totalLengthKB * 100).toStringAsFixed(2)
        : "0.00";

    sink.writeln("PROGRESS SUMMARY:");
    sink.writeln("  Remote folder: $remoteUpdateFolder");
    sink.writeln("  Total files: $totalFiles");
    sink.writeln("  Completed: $successful");
    sink.writeln("  Failed: $failed");
    sink.writeln("  In progress: $inProgress");
    sink.writeln(
        "  Downloaded: ${_formatBytes((receivedBytes * 1024).toInt())} / ${_formatBytes((totalLengthKB * 1024).toInt())}");
    sink.writeln("  Progress: $progressPercent%");
    sink.writeln("  Downloaded size: ${_formatBytes(totalSize)}");
    sink.writeln("");

    final recentFailures = downloadResults
        .where((r) => r["status"] == "failed")
        .toList()
        .reversed
        .take(10)
        .toList();

    if (recentFailures.isNotEmpty) {
      sink.writeln("RECENT FAILURES (last 10):");
      sink.writeln("-" * 80);
      for (final result in recentFailures) {
        final file = result["file"] as String;
        final error = result["error"] as String? ?? "Unknown error";
        sink.writeln("  File: $file");
        sink.writeln("    Error: ${error.split('\n').first}");
        sink.writeln("");
      }
    }

    sink.writeln("=" * 80);
    sink.writeln("");

    await sink.close();
    if (getCancelled?.call() ?? false) return;
    debugPrint("Periodic log: $progressPercent%");
  } catch (e) {
    if (getCancelled?.call() ?? false) return;
    debugPrint("Error saving periodic log: $e");
  }
}

/// Saves a detailed log of the download process
Future<void> _saveDownloadLog({
  required Directory updateFolder,
  required List<Map<String, dynamic>> downloadResults,
  required String remoteUpdateFolder,
  required int totalFiles,
}) async {
  try {
    final timestamp = DateTime.now();
    final logFileName = "download_${timestamp.millisecondsSinceEpoch}.log";

    Directory? logDir;
    if (Platform.isMacOS) {
      final appSupportDir = Platform.environment['HOME'];
      if (appSupportDir != null) {
        final bundleId = await _getBundleIdFromInfoPlist();
        if (bundleId != null) {
          logDir = Directory(
            path.join(
              appSupportDir,
              "Library",
              "Application Support",
              bundleId,
              "logs",
            ),
          );
          if (!await logDir.exists()) {
            await logDir.create(recursive: true);
          }
        }
      }
    }

    if (logDir == null || !await logDir.exists()) {
      logDir = updateFolder;
    }

    final logFile = File(path.join(logDir.path, logFileName));
    final sink = logFile.openWrite();

    // Calculate statistics
    final successful =
        downloadResults.where((r) => r["status"] == "success").length;
    final failed = downloadResults.where((r) => r["status"] == "failed").length;
    final totalSize = downloadResults.fold<int>(
      0,
      (sum, r) => sum + (r["size"] as int? ?? 0),
    );
    final expectedSize = downloadResults.fold<int>(
      0,
      (sum, r) => sum + (r["expectedSize"] as int? ?? 0),
    );
    final totalDuration = downloadResults.fold<int>(
      0,
      (sum, r) => sum + (r["duration"] as int? ?? 0),
    );

    sink.writeln("=" * 80);
    sink.writeln("DOWNLOAD LOG - ${timestamp.toIso8601String()}");
    sink.writeln("=" * 80);
    sink.writeln("");
    sink.writeln("SUMMARY:");
    sink.writeln("  Remote folder: $remoteUpdateFolder");
    sink.writeln("  Update folder: ${updateFolder.path}");
    sink.writeln("  Total files: $totalFiles");
    sink.writeln("  Successful downloads: $successful");
    sink.writeln("  Failed downloads: $failed");
    sink.writeln("  Total downloaded size: ${_formatBytes(totalSize)}");
    sink.writeln("  Expected total size: ${_formatBytes(expectedSize)}");
    sink.writeln(
        "  Total download time: ${_formatDuration(Duration(milliseconds: totalDuration))}");
    if (successful > 0) {
      sink.writeln(
          "  Average download time: ${_formatDuration(Duration(milliseconds: totalDuration ~/ successful))}");
    }
    sink.writeln("");

    sink.writeln("=" * 80);
    sink.writeln("DETAILED FILE INFORMATION");
    sink.writeln("=" * 80);
    sink.writeln("");

    final successfulFiles =
        downloadResults.where((r) => r["status"] == "success").toList();
    final failedFiles =
        downloadResults.where((r) => r["status"] == "failed").toList();

    if (successfulFiles.isNotEmpty) {
      sink.writeln("SUCCESSFUL DOWNLOADS (${successfulFiles.length}):");
      sink.writeln("-" * 80);
      for (final result in successfulFiles) {
        final file = result["file"] as String;
        final size = result["size"] as int;
        final expectedSize = result["expectedSize"] as int;
        final duration = Duration(milliseconds: result["duration"] as int);
        final startTime = result["startTime"] as String;
        final endTime = result["endTime"] as String;
        final sizeMatch = size == expectedSize ? "✓" : "⚠";

        sink.writeln("  File: $file");
        sink.writeln("    Status: SUCCESS $sizeMatch");
        sink.writeln(
            "    Size: ${_formatBytes(size)} (expected: ${_formatBytes(expectedSize)})");
        sink.writeln("    Duration: ${_formatDuration(duration)}");
        sink.writeln("    Start: $startTime");
        sink.writeln("    End: $endTime");
        sink.writeln("");
      }
    }

    if (failedFiles.isNotEmpty) {
      sink.writeln("FAILED DOWNLOADS (${failedFiles.length}):");
      sink.writeln("-" * 80);
      for (final result in failedFiles) {
        final file = result["file"] as String;
        final expectedSize = result["expectedSize"] as int;
        final duration = Duration(milliseconds: result["duration"] as int);
        final error = result["error"] as String? ?? "Unknown error";
        final startTime = result["startTime"] as String;
        final endTime = result["endTime"] as String;

        sink.writeln("  File: $file");
        sink.writeln("    Status: FAILED ✗");
        sink.writeln("    Expected size: ${_formatBytes(expectedSize)}");
        sink.writeln("    Duration: ${_formatDuration(duration)}");
        sink.writeln("    Start: $startTime");
        sink.writeln("    End: $endTime");
        sink.writeln("    Error: $error");
        sink.writeln("");
      }
    }

    // Write directory tree with sizes
    sink.writeln("=" * 80);
    sink.writeln("DIRECTORY STRUCTURE WITH SIZES");
    sink.writeln("=" * 80);
    sink.writeln("");

    if (await updateFolder.exists()) {
      await _writeDirectoryTree(sink, updateFolder, updateFolder.path, 0);
    }

    sink.writeln("");
    sink.writeln("=" * 80);
    sink.writeln("END OF LOG");
    sink.writeln("=" * 80);

    await sink.close();

    debugPrint("Download log: ${logFile.path}");
  } catch (e) {
    debugPrint("Error saving download log: $e");
  }
}

/// Gets bundle identifier from Info.plist (macOS)
Future<String?> _getBundleIdFromInfoPlist() async {
  if (!Platform.isMacOS) return null;

  try {
    final executablePath = Platform.resolvedExecutable;
    final bundleMatch =
        RegExp(r'^(.+\.app)/Contents/').firstMatch(executablePath);
    if (bundleMatch != null) {
      final bundlePath = bundleMatch.group(1);
      final infoPlistPath = path.join(bundlePath!, "Contents", "Info.plist");

      final infoPlistFile = File(infoPlistPath);
      if (await infoPlistFile.exists()) {
        final content = await infoPlistFile.readAsString();
        final bundleIdMatch = RegExp(
          r'<key>CFBundleIdentifier</key>\s*<string>([^<]+)</string>',
          caseSensitive: false,
        ).firstMatch(content);

        if (bundleIdMatch != null) {
          return bundleIdMatch.group(1);
        }
      }
    }
  } catch (e) {
    debugPrint("Warning: Could not read Info.plist: $e");
  }

  return null;
}

/// Formats bytes to human-readable string
String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return "$bytes B";
  } else if (bytes < 1024 * 1024) {
    return "${(bytes / 1024).toStringAsFixed(2)} KB";
  } else if (bytes < 1024 * 1024 * 1024) {
    return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
  } else {
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }
}

/// Formats duration to human-readable string
String _formatDuration(Duration duration) {
  if (duration.inMilliseconds < 1000) {
    return "${duration.inMilliseconds}ms";
  } else if (duration.inSeconds < 60) {
    return "${duration.inSeconds}s";
  } else {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return "${minutes}m ${seconds}s";
  }
}

/// Writes directory tree with sizes to the log
Future<void> _writeDirectoryTree(
  IOSink sink,
  Directory dir,
  String basePath,
  int indent,
) async {
  try {
    final entries = dir.listSync();
    entries.sort((a, b) {
      if (a is Directory && b is File) return -1;
      if (a is File && b is Directory) return 1;
      return a.path.compareTo(b.path);
    });

    for (final entry in entries) {
      final relativePath = path.relative(entry.path, from: basePath);
      final indentStr = "  " * indent;

      if (entry is Directory) {
        int dirSize = 0;
        try {
          dirSize = await _getDirectorySize(entry);
        } catch (e) {
          // Ignore errors
        }
        sink.writeln("$indentStr📁 $relativePath/ (${_formatBytes(dirSize)})");
        await _writeDirectoryTree(sink, entry, basePath, indent + 1);
      } else if (entry is File) {
        int fileSize = 0;
        try {
          fileSize = await entry.length();
        } catch (e) {
          // Ignore errors
        }
        sink.writeln("$indentStr📄 $relativePath (${_formatBytes(fileSize)})");
      }
    }
  } catch (e) {
    // Ignore errors when listing directory
  }
}

/// Calculates total size of a directory recursively
Future<int> _getDirectorySize(Directory dir) async {
  int size = 0;
  try {
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        try {
          size += await entity.length();
        } catch (e) {
          // Ignore errors
        }
      }
    }
  } catch (e) {
    // Ignore errors
  }
  return size;
}
