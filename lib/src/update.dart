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

      // Track download results
      final downloadResults = <Map<String, dynamic>>[];
      final updateFolder = Directory(path.join(dir.path, "update"));

      // Limit concurrent downloads to avoid "Too many open files" error and DNS overload
      // Reduced to 5 to prevent DNS lookup failures when too many connections are opened simultaneously
      const maxConcurrentDownloads = 5;
      final activeDownloads = <Completer<void>>[];
      final downloadQueue = <FileHashModel>[];

      // Add all files to the download queue
      for (final file in changes) {
        if (file != null) {
          downloadQueue.add(file);
        }
      }

      // Process downloads with concurrency control
      unawaited(
        () async {
          print(
              "Starting download process: ${downloadQueue.length} files in queue");

          // Setup periodic log saving (every 10 seconds)
          Directory? logDir;
          String? logFileName;
          Timer? periodicLogTimer;

          // Determine log directory
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
            final initialSink = logFile.openWrite();
            initialSink.writeln("=" * 80);
            initialSink
                .writeln("DOWNLOAD LOG - ${timestamp.toIso8601String()}");
            initialSink.writeln("=" * 80);
            initialSink.writeln("");
            initialSink.writeln("INITIAL STATUS:");
            initialSink.writeln("  Remote folder: $remoteUpdateFolder");
            initialSink.writeln("  Update folder: ${updateFolder.path}");
            initialSink.writeln("  Total files: $totalFiles");
            initialSink.writeln(
                "  Total size: ${_formatBytes((totalLengthKB * 1024).toInt())}");
            initialSink.writeln("  Started at: ${timestamp.toIso8601String()}");
            initialSink.writeln("");
            initialSink.writeln(
                "Periodic updates will be appended every 10 seconds...");
            initialSink.writeln("");
            await initialSink.close();
            print("Download log initialized: ${logFile.path}");
          } catch (e) {
            print("Warning: Could not create initial log file: $e");
          }

          // Function to save log periodically
          Future<void> savePeriodicLog() async {
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
              );
            } catch (e) {
              print("Error saving periodic log: $e");
            }
          }

          // Start periodic log saving every 10 seconds
          periodicLogTimer = Timer.periodic(Duration(seconds: 10), (_) {
            unawaited(savePeriodicLog());
          });

          while (downloadQueue.isNotEmpty || activeDownloads.isNotEmpty) {
            // Start new downloads if we have capacity
            while (activeDownloads.length < maxConcurrentDownloads &&
                downloadQueue.isNotEmpty) {
              final file = downloadQueue.removeAt(0);
              print(
                  "Starting download: ${file.filePath} (${activeDownloads.length + 1}/$maxConcurrentDownloads active)");

              // Small delay between starting downloads to avoid DNS overload
              if (activeDownloads.isNotEmpty) {
                await Future.delayed(Duration(milliseconds: 100));
              }

              final startTime = DateTime.now();

              // Create a completer to track this download
              final completer = Completer<void>();
              activeDownloads.add(completer);

              // Start the download
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
              ).then((_) async {
                try {
                  completedFiles += 1;
                  final endTime = DateTime.now();
                  final duration = endTime.difference(startTime);

                  // Get file info
                  final fullPath = path.join(updateFolder.path, file.filePath);
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
                } finally {
                  // Always remove completer and complete it, even if there was an error
                  activeDownloads.remove(completer);
                  if (!completer.isCompleted) {
                    completer.complete();
                  }
                }
              }).catchError((error, stackTrace) {
                final endTime = DateTime.now();
                final duration = endTime.difference(startTime);

                // Extract retry information from error message
                final errorString = error.toString();
                int retryAttempts = 3; // Default max retries
                bool hasRetryInfo = false;
                
                if (errorString.contains('Retry attempts:')) {
                  final retryMatch = RegExp(r'Retry attempts: (\d+)').firstMatch(errorString);
                  if (retryMatch != null) {
                    retryAttempts = int.tryParse(retryMatch.group(1) ?? '3') ?? 3;
                    hasRetryInfo = true;
                  }
                }

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
                  "retryAttempts": retryAttempts,
                  "hadRetries": hasRetryInfo,
                });

                print("ERROR: Failed to download file: ${file.filePath}");
                print("  Error: $error");
                print("  Stack trace: $stackTrace");
                responseStream.addError(
                  Exception("Failed to download update file:\n"
                      "  File: ${file.filePath}\n"
                      "  Remote folder: $remoteUpdateFolder\n"
                      "  Error: $error"),
                  stackTrace,
                );

                // Remove completer and complete it
                activeDownloads.remove(completer);
                if (!completer.isCompleted) {
                  completer.complete();
                }
              });
            }

            // Wait for at least one download to complete before starting new ones
            if (activeDownloads.isNotEmpty) {
              // Create a copy of the list to avoid modification during iteration
              final futures = activeDownloads.map((c) => c.future).toList();
              if (futures.isNotEmpty) {
                print(
                    "Waiting for ${futures.length} active downloads to complete...");
                await Future.any(futures);
                print(
                    "At least one download completed. Active: ${activeDownloads.length}, Queue: ${downloadQueue.length}");
              }
              // Small delay to prevent tight loop and allow UI to update
              await Future.delayed(Duration(milliseconds: 10));
            } else if (downloadQueue.isNotEmpty) {
              // If queue is not empty but no active downloads, something might be wrong
              // But continue anyway with a small delay
              print(
                  "Warning: Queue not empty but no active downloads. Queue: ${downloadQueue.length}");
              await Future.delayed(Duration(milliseconds: 50));
            } else {
              // All done, exit loop
              print("All downloads completed!");
              break;
            }
          }

          // Cancel periodic log timer
          periodicLogTimer.cancel();

          // Generate and save final download log
          await _saveDownloadLog(
            updateFolder: updateFolder,
            downloadResults: downloadResults,
            remoteUpdateFolder: remoteUpdateFolder,
            totalFiles: totalFiles,
          );

          await responseStream.close();
        }(),
      );

      return responseStream.stream;
    }
  } catch (e, stackTrace) {
    print("ERROR: Failed to initialize update process");
    print("  Executable path: $executablePath");
    print("  Directory path: ${dir.path}");
    print("  Remote update folder: $remoteUpdateFolder");
    print("  Number of files to update: ${changes.length}");
    print("  Error: $e");
    print("  Stack trace: $stackTrace");
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

  return responseStream.stream;
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
}) async {
  try {
    final timestamp = DateTime.now();
    final logFile = File(path.join(logDir.path, logFileName));

    // Open in append mode to add periodic updates
    final sink = logFile.openWrite(mode: FileMode.append);

    sink.writeln("");
    sink.writeln("=" * 80);
    sink.writeln("PERIODIC UPDATE - ${timestamp.toIso8601String()}");
    sink.writeln("=" * 80);
    sink.writeln("");

    // Calculate current statistics
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

    // Show recent failures (last 10)
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
        final retryAttempts = result["retryAttempts"] as int? ?? 0;
        final hadRetries = result["hadRetries"] as bool? ?? false;
        sink.writeln("  File: $file");
        if (hadRetries && retryAttempts > 0) {
          sink.writeln("    Retry attempts: $retryAttempts (all failed)");
        }
        sink.writeln(
            "    Error: ${error.split('\n').first}"); // First line only
        sink.writeln("");
      }
    }

    sink.writeln("=" * 80);
    sink.writeln("");

    await sink.close();
    print(
        "Periodic log saved: $progressPercent% complete, $successful/$totalFiles files");
  } catch (e) {
    print("ERROR: Failed to save periodic log: $e");
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

    // Determine log directory based on platform
    Directory? logDir;
    if (Platform.isMacOS) {
      final appSupportDir = Platform.environment['HOME'];
      if (appSupportDir != null) {
        // Try to get bundle identifier from Info.plist
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
          // Create log directory if it doesn't exist
          if (!await logDir.exists()) {
            await logDir.create(recursive: true);
          }
        }
      }
    }

    // Fallback to update folder if no log directory found
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

    // Write log header
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

    // Write detailed file information
    sink.writeln("=" * 80);
    sink.writeln("DETAILED FILE INFORMATION");
    sink.writeln("=" * 80);
    sink.writeln("");

    // Group by status
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
        final retryAttempts = result["retryAttempts"] as int? ?? 0;
        final hadRetries = result["hadRetries"] as bool? ?? false;

        sink.writeln("  File: $file");
        sink.writeln("    Status: FAILED ✗");
        sink.writeln("    Expected size: ${_formatBytes(expectedSize)}");
        sink.writeln("    Duration: ${_formatDuration(duration)}");
        if (hadRetries && retryAttempts > 0) {
          sink.writeln("    Retry attempts: $retryAttempts (all failed)");
        }
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

    // Print summary to console (minimal)
    print("Download log saved to: ${logFile.path}");
    print(
        "Summary: $successful/$totalFiles successful, ${_formatBytes(totalSize)} downloaded");
    if (failed > 0) {
      print(
          "Warning: $failed file(s) failed to download. See log for details.");
    }
  } catch (e, stackTrace) {
    print("ERROR: Failed to save download log: $e");
    print("Stack trace: $stackTrace");
  }
}

/// Gets bundle identifier from Info.plist (macOS)
Future<String?> _getBundleIdFromInfoPlist() async {
  if (!Platform.isMacOS) return null;

  try {
    final executablePath = Platform.resolvedExecutable;
    // Extract bundle path from executable path
    // /Applications/app.app/Contents/MacOS/app -> /Applications/app.app
    final bundleMatch =
        RegExp(r'^(.+\.app)/Contents/').firstMatch(executablePath);
    if (bundleMatch != null) {
      final bundlePath = bundleMatch.group(1);
      final infoPlistPath = path.join(bundlePath!, "Contents", "Info.plist");

      final infoPlistFile = File(infoPlistPath);
      if (await infoPlistFile.exists()) {
        // Read and parse Info.plist
        final content = await infoPlistFile.readAsString();

        // Simple XML parsing for CFBundleIdentifier
        // Look for <key>CFBundleIdentifier</key> followed by <string>value</string>
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
    // If we can't read Info.plist, fall back to extraction from path
    print("Warning: Could not read Info.plist, using fallback: $e");
  }

  // Fallback: try to extract from executable path
  final executablePath = Platform.resolvedExecutable;
  final match = RegExp(r'/([^/]+)\.app/Contents/').firstMatch(executablePath);
  if (match != null) {
    final appName = match.group(1);
    // Try common bundle ID patterns
    final possibleIds = [
      "com.puzzl.$appName",
      "com.$appName",
      "$appName",
    ];
    // Return first one that might work (we'll let the system handle if it doesn't exist)
    return possibleIds.first;
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
      // Directories first, then files
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
